# `x`
Want a development container?
> `x` gon' give it to ya'.

# Usage
* Put `x` somewhere in your `PATH`.
* Create an `x.json` file for your project.
* Run `x <COMMAND>` to run your command inside a development container.
* To get the ID of the container run `x` without any arguments.

# Features
* Zero dependencies besides Docker and Python.
* Supports X11 out of the box.
* Automatically mounts the project directory, your home directory, and any extra mounted partitions inside the container.

## Get a Shell Inside the Container
```
x bash
```

## Removing the Container
```sh
docker rm -f $(x)
```

# Configuration
`x` looks for `x.json` or `.x.json` files for the project configuration.
Additionally you can override fields from the project configuration by supplying your a `.x.user.json` or a `x.user.json`.

* `image` - An image to use for the container (example: `ubuntu:19.04`)
* `dockerfile` - The path to a Dockerfile to use to build the container.
* `docker_context` - The context directory to use to build the image if `dockerfile` is supplied.
* `docker_network` - The argument to pass to docker's `--network` flag (default: `host`).

## Example Configuration
For more examples take a look at the `./examples` directory.

```json
{
    "image": "ubuntu:19.04"
}
```
