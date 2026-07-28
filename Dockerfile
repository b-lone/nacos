# Copyright 1999-2026 Alibaba Group Holding Ltd.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

ARG REGISTRY_HOST=127.0.0.1
ARG BASE_IMAGE=${REGISTRY_HOST}:5443/mirror/dockerhub/library/python:3.13-slim@sha256:800ac3fc34cb04346a5669cc677cb4d65e23be59e1b64a1efa60fe4b230263ff

FROM ${BASE_IMAGE} AS base

ARG DEBIAN_MIRROR=http://mirrors.aliyun.com/debian
ARG DEBIAN_SECURITY_MIRROR=http://mirrors.aliyun.com/debian-security

RUN sed --in-place \
        --expression "s|http://deb.debian.org/debian-security|${DEBIAN_SECURITY_MIRROR}|g" \
        --expression "s|http://deb.debian.org/debian|${DEBIAN_MIRROR}|g" \
        /etc/apt/sources.list.d/debian.sources

FROM base AS builder

ENV DEBIAN_FRONTEND=noninteractive

RUN --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    apt-get update \
    && apt-get install --yes --no-install-recommends \
        ca-certificates \
        default-jdk-headless \
        maven

WORKDIR /build

COPY . .

RUN mvn \
        --batch-mode \
        '-Prelease-nacos,!dev' \
        -Dmaven.test.skip=true \
        clean \
        install \
        -U \
    && archive="$(find distribution/target -maxdepth 1 -type f -name 'nacos-server-*.tar.gz' -print -quit)" \
    && test -n "${archive}" \
    && mkdir -p /opt/nacos \
    && tar --extract --gzip --file "${archive}" --strip-components=1 --directory /opt/nacos

FROM base

ARG APP_UID=501
ARG APP_GID=501

ENV DEBIAN_FRONTEND=noninteractive \
    HOME=/home/nacos \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    TZ=Asia/Shanghai

RUN --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    apt-get update \
    && apt-get install --yes --no-install-recommends \
        ca-certificates \
        curl \
        default-jre-headless \
        tzdata \
    && groupadd --gid "${APP_GID}" nacos \
    && useradd \
        --uid "${APP_UID}" \
        --gid "${APP_GID}" \
        --home-dir "${HOME}" \
        --create-home \
        --shell /usr/sbin/nologin \
        nacos

COPY --from=builder --chown=nacos:nacos /opt/nacos /home/nacos
COPY --chown=nacos:nacos --chmod=0755 docker/nacos-entrypoint.sh /usr/local/bin/nacos-entrypoint

RUN cp /home/nacos/conf/application.properties /home/nacos/conf/application.properties.template \
    && install --directory --owner=nacos --group=nacos --mode=0750 \
        /home/nacos/data \
        /home/nacos/logs

WORKDIR /home/nacos

USER nacos

EXPOSE 8848 9848 9849

ENTRYPOINT ["/usr/local/bin/nacos-entrypoint"]
