#!/bin/sh

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

set -eu

readonly NACOS_HOME=/home/nacos
readonly APPLICATION_TEMPLATE="${NACOS_HOME}/conf/application.properties.template"
readonly APPLICATION_PROPERTIES="${NACOS_HOME}/conf/application.properties"

fail() {
    printf 'nacos-entrypoint: %s\n' "$1" >&2
    exit 1
}

require_value() {
    value_name=$1
    eval "value=\${${value_name}:-}"
    [ -n "${value}" ] || fail "${value_name} is required"
}

require_secret_file() {
    secret_name=$1
    eval "secret_path=\${${secret_name}:-}"
    [ -n "${secret_path}" ] || fail "${secret_name} is required"
    [ -f "${secret_path}" ] || fail "${secret_name} does not reference a regular file"
    [ -r "${secret_path}" ] || fail "${secret_name} is not readable"
    [ -s "${secret_path}" ] || fail "${secret_name} is empty"
    [ -z "$(find "${secret_path}" -maxdepth 0 -perm /077 -print -quit)" ] \
        || fail "${secret_name} must not grant group or other permissions"
}

read_secret() {
    secret_path=$1
    secret_value=$(tr -d '\r\n' < "${secret_path}")
    [ -n "${secret_value}" ] || fail "${secret_path} has no usable value"
    printf '%s' "${secret_value}"
}

escape_property_value() {
    printf '%s' "$1" | sed \
        -e 's/\\/\\\\/g' \
        -e 's/=/\\=/g' \
        -e 's/:/\\:/g'
}

append_property() {
    property_name=$1
    property_value=$(escape_property_value "$2")
    printf '%s=%s\n' "${property_name}" "${property_value}" >> "${APPLICATION_PROPERTIES}"
}

validate_runtime_configuration() {
    require_value NACOS_DATABASE_HOST
    require_value NACOS_DATABASE_PORT
    require_value NACOS_DATABASE_NAME
    require_value NACOS_DATABASE_USER
    require_value NACOS_JAVA_XMS
    require_value NACOS_JAVA_XMX

    case "${NACOS_DATABASE_HOST}" in
        *[!A-Za-z0-9._-]*) fail "NACOS_DATABASE_HOST has an invalid value" ;;
    esac
    case "${NACOS_DATABASE_PORT}" in
        *[!0-9]*|'') fail "NACOS_DATABASE_PORT has an invalid value" ;;
    esac
    [ "${NACOS_DATABASE_PORT}" -ge 1 ] && [ "${NACOS_DATABASE_PORT}" -le 65535 ] \
        || fail "NACOS_DATABASE_PORT is outside the valid range"
    case "${NACOS_DATABASE_NAME}" in
        *[!A-Za-z0-9_]*) fail "NACOS_DATABASE_NAME has an invalid value" ;;
    esac
    case "${NACOS_DATABASE_USER}" in
        *[!A-Za-z0-9_]*) fail "NACOS_DATABASE_USER has an invalid value" ;;
    esac
    printf '%s' "${NACOS_JAVA_XMS}" | grep -Eq '^[1-9][0-9]*[mMgG]$' \
        || fail "NACOS_JAVA_XMS has an invalid value"
    printf '%s' "${NACOS_JAVA_XMX}" | grep -Eq '^[1-9][0-9]*[mMgG]$' \
        || fail "NACOS_JAVA_XMX has an invalid value"

    require_secret_file NACOS_DATABASE_PASSWORD_FILE
    require_secret_file NACOS_AUTH_TOKEN_SECRET_FILE
    require_secret_file NACOS_SERVER_IDENTITY_KEY_FILE
    require_secret_file NACOS_SERVER_IDENTITY_VALUE_FILE
}

write_application_properties() {
    database_password=$(read_secret "${NACOS_DATABASE_PASSWORD_FILE}")
    auth_token_secret=$(read_secret "${NACOS_AUTH_TOKEN_SECRET_FILE}")
    server_identity_key=$(read_secret "${NACOS_SERVER_IDENTITY_KEY_FILE}")
    server_identity_value=$(read_secret "${NACOS_SERVER_IDENTITY_VALUE_FILE}")
    database_url="jdbc:postgresql://${NACOS_DATABASE_HOST}:${NACOS_DATABASE_PORT}/${NACOS_DATABASE_NAME}?connectTimeout=5&socketTimeout=10&tcpKeepAlive=true"

    printf '%s' "${auth_token_secret}" | base64 --decode >/dev/null 2>&1 \
        || fail "NACOS_AUTH_TOKEN_SECRET_FILE is not valid Base64"
    decoded_token_bytes=$(printf '%s' "${auth_token_secret}" | base64 --decode | wc -c | tr -d ' ')
    [ "${decoded_token_bytes}" -ge 32 ] \
        || fail "NACOS_AUTH_TOKEN_SECRET_FILE must decode to at least 32 bytes"

    cp "${APPLICATION_TEMPLATE}" "${APPLICATION_PROPERTIES}"
    chmod 0600 "${APPLICATION_PROPERTIES}"

    append_property nacos.plugin.datasource-dialect.type postgresql
    append_property nacos.plugin.datasource.db.num 1
    append_property nacos.plugin.datasource.db.url.0 "${database_url}"
    append_property nacos.plugin.datasource.db.user "${NACOS_DATABASE_USER}"
    append_property nacos.plugin.datasource.db.password "${database_password}"
    append_property nacos.plugin.datasource.db.pool.config.driver-class-name org.postgresql.Driver
    append_property nacos.plugin.datasource.db.pool.config.connection-timeout 5000
    append_property nacos.plugin.datasource.db.pool.config.validation-timeout 3000
    append_property nacos.plugin.datasource.db.query-timeout 5
    append_property nacos.core.auth.enabled true
    append_property nacos.core.auth.admin.enabled true
    append_property nacos.core.auth.console.enabled true
    append_property nacos.core.auth.server.identity.key "${server_identity_key}"
    append_property nacos.core.auth.server.identity.value "${server_identity_value}"
    append_property nacos.plugin.auth.nacos.token.secret.key "${auth_token_secret}"

    unset database_password auth_token_secret server_identity_key server_identity_value database_url \
        decoded_token_bytes property_value
}

start_nacos() {
    exec java \
        "-Xms${NACOS_JAVA_XMS}" \
        "-Xmx${NACOS_JAVA_XMX}" \
        -Xmn256m \
        -XX:+UseG1GC \
        -XX:-OmitStackTraceInFastThrow \
        -XX:+HeapDumpOnOutOfMemoryError \
        "-XX:HeapDumpPath=${NACOS_HOME}/logs/java_heapdump.hprof" \
        "-Xlog:gc*:file=${NACOS_HOME}/logs/nacos_gc.log:time,tags:filecount=10,filesize=100m" \
        --add-opens=java.base/java.lang=ALL-UNNAMED \
        --add-opens=java.base/java.lang.reflect=ALL-UNNAMED \
        --add-opens=java.base/java.util=ALL-UNNAMED \
        -Dnacos.standalone=true \
        -Dnacos.functionMode=config \
        -Dnacos.deployment.type=merged \
        "-Dloader.path=${NACOS_HOME}/plugins,${NACOS_HOME}/plugins/health,${NACOS_HOME}/plugins/cmdb,${NACOS_HOME}/plugins/selector" \
        "-Dnacos.home=${NACOS_HOME}" \
        -jar "${NACOS_HOME}/target/nacos-server.jar" \
        "--spring.config.additional-location=file:${NACOS_HOME}/conf/" \
        "--logging.config=${NACOS_HOME}/conf/nacos-logback.xml" \
        --server.max-http-request-header-size=524288 \
        nacos.nacos
}

[ -f "${APPLICATION_TEMPLATE}" ] || fail "application properties template is missing"
validate_runtime_configuration
write_application_properties
start_nacos
