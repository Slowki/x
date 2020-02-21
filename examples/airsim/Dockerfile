# syntax=docker/dockerfile:1.0.0-experimental
FROM tensorflow/tensorflow:latest-gpu-py3

RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
    clang-3.9 \
    curl \
    git \
    git \
    libasound2 \
    libglvnd-dev \
    libgtk-3-0 \
    libgtk2.0-0 \
    libgtk2.0-0 \
    libopenjfx-jni \
    libpango-1.0-0 \
    libpangoft2-1.0-0 \
    libxext6 \
    libxi6 \
    libxrender1 \
    libxtst6 \
    mono-devel \
    mono-dmcs \
    mono-xbuild \
    rsync \
    sudo \
    unzip \
    wget \
    xdg-user-dirs

RUN useradd build && \
    mkdir -p /home/build && \
    chown build /home/build && \
    usermod -aG sudo build && \
    echo "build ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers

RUN mkdir -p -m 0600 ~/.ssh && ssh-keyscan github.com >> ~/.ssh/known_hosts

ARG UNREAL_VERSION=4.18
RUN --mount=type=ssh git clone --depth 1 -b $UNREAL_VERSION git@github.com:EpicGames/UnrealEngine && \
    chown -R build:build UnrealEngine && \
    cd UnrealEngine && \
    su build -c ./Setup.sh && \
    su build -c ./GenerateProjectFiles.sh && \
    su build -c make

ARG AIRSIM_VERSION=v.1.2.2
RUN curl -SSfL https://github.com/microsoft/AirSim/archive/$AIRSIM_VERSION.tar.gz | tar -xzf - && \
    chown -R build:build AirSim-$AIRSIM_VERSION && \
    cd AirSim-$AIRSIM_VERSION && \
    su build -c ./setup.sh && \
    su build -c ./build.sh

ARG PYCHARM_VERSION=2019.3.2
RUN curl -sSfL https://download-cf.jetbrains.com/python/pycharm-professional-2019.3.2.tar.gz | tar -xzf - && \
    mv pycharm-$PYCHARM_VERSION /opt/pycharm && \
    ln -s /opt/pycharm/bin/pycharm.sh /usr/bin/pycharm

ENV NVIDIA_DRIVER_CAPABILITIES=all
