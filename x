#!/usr/bin/env python3

"""A development environment tool."""

import dataclasses
import getpass
import grp
import json
import logging
import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import (
    Any,
    Dict,
    List,
    Mapping,
    MutableMapping,
    NoReturn,
    Optional,
    Set,
    Type,
    Union,
)

LOGGER = logging.Logger(__name__)
THIS_FILE = Path(__file__)

DISPLAY = "DISPLAY"

CONFIG_FILE_NAMES = frozenset(["x.json", ".x.json"])
USER_CONFIG_FILE_NAMES = frozenset([".x.user.json", "x.user.json"])

X_SOCK = Path("/tmp/.X11-unix")
KVM = Path("/dev/kvm")
DOCKER_SOCKET = Path("/var/run/docker.sock")
DOCKER_BIN = shutil.which("docker")


@dataclasses.dataclass
class Configuration:
    """The configuration for the current project."""

    #: The container image to use for this project.
    image: Optional[str] = None
    dockerfile: Optional[str] = None
    docker_buildkit: Optional[bool] = False
    docker_context: Optional[str] = None
    docker_secrets: Optional[List[str]] = None
    docker_ssh: Optional[bool] = False
    docker_network: str = "host"

    environment: str = "docker"

    @staticmethod
    def from_project_file(project_file_path: Path) -> "Configuration":
        """Construct a :ref:`Configuration` from a JSON file."""
        FIELDS: Mapping[
            str, dataclasses.Field
        ] = Configuration.__dataclass_fields__  # type: ignore

        data: Dict[Any, Any] = {}
        files = [project_file_path]

        for path in CONFIG_FILE_NAMES:
            possible_global_config = Path.home() / path
            if possible_global_config.exists():
                files.append(possible_global_config)
                break

        for user_path in USER_CONFIG_FILE_NAMES:
            possible_user_config = project_file_path.parent / user_path
            if possible_user_config.exists():
                files.append(possible_user_config)
                break

        for file_path in files:
            with file_path.open() as file:
                new_data = json.load(file)
                if "image" in new_data or "dockerfile" in new_data:
                    data["image"] = None
                    data["dockerfile"] = None
                data.update(new_data)

        kwargs = {}
        for name, value in data.items():
            native_name = name.replace("-", "_")
            field_value = FIELDS.get(native_name)
            if field_value:
                kwargs[native_name] = value
            else:
                LOGGER.error(f"Unknown configuration field `{name}`", file=sys.stderr)

        configuration = Configuration(**kwargs)
        if configuration.environment not in EXECUTOR_MAP:
            sys.exit(f"Unknown environment {configuration.environment}")
        if configuration.image and configuration.dockerfile:
            sys.exit(f"image and dockerfile cannot both be set in your configuration.")
        if not (configuration.image or configuration.dockerfile):
            sys.exit(f"Either image or dockerfile must be set in your configuration.")

        return configuration


class Executor:
    def __init__(self, configuration: Configuration, project_dir: Path):
        self.configuration: Configuration = configuration
        self.project_dir: Path = project_dir.absolute()

        self.username = getpass.getuser()
        self.uid = os.getuid()
        self.gid = os.getgid()
        self.home = Path.home()

    def get_volumes(self) -> Set[str]:
        """Get the list of volumes to mount.

        Returns:
            A set of paths to mount.
        """
        volumes = {str(self.home)}

        lsblk = subprocess.run(
            ["lsblk", "-o", "MOUNTPOINT"],
            stdout=subprocess.PIPE,
            universal_newlines=True,
        )
        if lsblk.returncode == 0:
            volumes.update(
                {line for line in lsblk.stdout.splitlines()[1:] if line.strip()}
            )

        volumes.add(os.fspath(self.project_dir))
        volumes.update(
            {os.fspath(path) for path in (X_SOCK, KVM, DOCKER_SOCKET) if path.exists()}
        )

        if DOCKER_BIN and os.path.exists(DOCKER_BIN):
            volumes.add(DOCKER_BIN)

        return volumes.difference(frozenset({"/", "/boot"}))

    def get_groups(self) -> Mapping[str, int]:
        """Get the groups to create.

        Returns:
            A mapping from group name to GID.
        """
        groups: MutableMapping[str, int] = {}

        for path in (KVM, DOCKER_SOCKET):
            if path.exists():
                owner = path.stat().st_gid
                if owner != 0:
                    group_name = grp.getgrgid(owner)
                    groups[group_name.gr_name] = owner

        return groups

    def execute_in_container(self, command: List[str]) -> Optional[NoReturn]:
        """Execute a command inside the container."""
        raise NotImplementedError("Executor is an abstract class")

    def x_allow_host(self, hostname: str) -> bool:
        """Allow a host to access the local X server.

        Returns:
            True if the xhost command succeeds.
        """
        xhost_result = subprocess.run(
            ["xhost", "+local:" + hostname],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        if xhost_result.returncode != 0:
            LOGGER.warn(xhost_result.stderr)
            return False
        return True


class DockerExecutor(Executor):
    def find_container(self) -> Optional[str]:
        """Try to find an existing docker container to execute in.

        Returns:
            The ID of the container.
        """
        docker_subprocess = subprocess.run(
            [
                "docker",
                "container",
                "ls",
                "--filter",
                f"label=x={self.project_dir}",
                "--format={{json .}}",
            ],
            check=True,
            stdout=subprocess.PIPE,
            universal_newlines=True,
        )
        container_descriptions = [
            json.loads(line) for line in docker_subprocess.stdout.splitlines()
        ]

        selected_container: Optional[str] = None
        containers_to_delete = []
        for container in container_descriptions:
            if (
                not self.configuration.image
                or container["Image"] == self.configuration.image
            ):
                if selected_container:
                    containers_to_delete.append(selected_container)
                selected_container = container["ID"]
            else:
                containers_to_delete.append(container["ID"])

        if containers_to_delete:
            subprocess.run(
                ["docker", "container", "rm", "-f"] + containers_to_delete,
                check=True,
                stdout=subprocess.PIPE,
            )
        return selected_container

    def spawn_container(self) -> str:
        """Spawn a Docker container to execute in.

        Returns:
            The ID of the new container.
        """
        image = self.configuration.image or self.build_image()

        spawn_command = [
            "docker",
            "run",
            "--rm",
            "-l",
            f"x={self.project_dir}",
            "-d",
            "--gpus=all",
            f"--network={self.configuration.docker_network}",
        ]
        for volume in self.get_volumes():
            spawn_command.extend(("-v", f"{volume}:{volume}"))

        if DISPLAY in os.environ:
            os.environ[DISPLAY]

        startup_command = []

        if self.uid != 0:
            groups = self.get_groups()
            for name, gid in groups.items():
                startup_command.append(f"groupadd -g {gid} {name}")
            add_groups = "-G " + ",".join(groups.keys()) if groups else ""
            startup_command.append(
                f"useradd -u {self.uid} {add_groups} -Mo {self.username}"
            )

        spawn_subprocess = subprocess.run(
            spawn_command
            + [image, "sh", "-c", " && ".join(startup_command + ["sleep infinity"])],
            check=True,
            stdout=subprocess.PIPE,
            universal_newlines=True,
        )

        id = spawn_subprocess.stdout.strip().splitlines()[-1]
        inspect = subprocess.run(
            ["docker", "inspect", "--format={{ .Config.Hostname }}", id],
            stdout=subprocess.PIPE,
            universal_newlines=True,
        )
        if inspect.returncode == 0:
            # Enable X11 access for the new container
            self.x_allow_host(inspect.stdout.strip())
        time.sleep(0.1)  # A terrible way to wait for the container to initialize
        return id

    def build_image(self) -> str:
        """Build a Docker image.

        Returns:
            The ID of the new image.
        """
        with tempfile.NamedTemporaryFile() as id_file:
            assert self.configuration.dockerfile is not None
            dockerfile = self.project_dir / self.configuration.dockerfile
            context = (
                self.project_dir / self.configuration.docker_context
                if self.configuration.docker_context
                else dockerfile.parent
            )

            env = os.environ.copy()
            if self.configuration.docker_buildkit:
                env["DOCKER_BUILDKIT"] = "1"

            build_command: List[Union[str, Path]] = [
                "docker",
                "build",
                "-f",
                dockerfile,
                "--iidfile",
                id_file.name,
            ]

            if self.configuration.docker_ssh:
                build_command.append("--ssh=default")

            if self.configuration.docker_secrets:
                for secret in self.configuration.docker_secrets:
                    build_command.extend(
                        ("--secret", secret.replace("$HOME", str(Path.home())))
                    )

            build_result = subprocess.run(build_command + [context], env=env)
            if build_result.returncode != 0:
                sys.exit(build_result.returncode)
            return Path(id_file.name).read_text().strip()

    def execute_in_container(self, command: List[str]) -> Optional[NoReturn]:
        """Run the given command inside the container and exit."""
        container = self.find_container() or self.spawn_container()
        docker_exec = [
            "docker",
            "exec",
            f"--user={self.username}",
            f"--env=HOME={self.home}",
            f"--workdir={Path.cwd()}",
            "-it" if sys.stdout.isatty() or sys.stderr.isatty() else "-i",
        ]
        if DISPLAY in os.environ:
            docker_exec.append(f"--env={DISPLAY}={os.environ[DISPLAY]}")

        if command:
            os.execvp("docker", docker_exec + [container] + command)

        # If `command` is empty then just print the container's ID
        print(container)
        return None


EXECUTOR_MAP: Mapping[str, Type[Executor]] = {"docker": DockerExecutor}


def find_project_file() -> Optional[Path]:
    """Try to find the configuration file for the current project."""
    cwd = Path.cwd()

    search_paths = [cwd]
    search_paths.extend(cwd.parents)
    search_paths.extend(THIS_FILE.parents)

    for path in search_paths:
        for file in (path / name for name in CONFIG_FILE_NAMES):
            if file.exists():
                return file

    return None


def main(argv: List[str]) -> int:
    """The main CLI entrypoint."""
    project_file = find_project_file()
    if project_file is None:
        LOGGER.critical("No project files found")
        return 1

    project_dir = project_file.parent

    # Support BAZEL_REAL style workflow where `x` will forward to `tools/x` by default
    if os.environ.get("X_REAL") is None:
        os.environ["X_REAL"] = os.fspath(THIS_FILE.absolute())
        for override_file in [
            project_dir / "tools" / "x",
            project_dir / "tools" / "x.py",
        ]:
            if override_file.exists():
                os.execv(override_file, [str(override_file)] + argv)

    configuration = Configuration.from_project_file(project_file)
    executor_class = EXECUTOR_MAP.get(configuration.environment.lower())

    if executor_class is None:
        LOGGER.critical("Unsupported environment '{configuration.environment}'")
        return 1

    executor_class(configuration, project_dir).execute_in_container(argv)
    return 0


if __name__ == "__main__":
    logging.basicConfig()
    sys.exit(main(sys.argv[1:]))
