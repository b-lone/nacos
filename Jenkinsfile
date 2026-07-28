/*
 * Copyright 1999-2026 Alibaba Group Holding Ltd.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

pipeline {
    agent {
        label 'built-in'
    }

    options {
        skipDefaultCheckout(true)
        disableConcurrentBuilds()
        timestamps()
        buildDiscarder(logRotator(numToKeepStr: '30', daysToKeepStr: '30'))
    }

    parameters {
        string(
            name: 'REGISTRY_HOST',
            defaultValue: '127.0.0.1',
            description: 'Docker Registry host without scheme or port.',
            trim: true
        )
        string(
            name: 'GIT_REF',
            defaultValue: '*/develop',
            description: 'Git branch, tag, or exact revision resolved by Jenkins.',
            trim: true
        )
    }

    environment {
        PATH = "/usr/local/bin:/opt/homebrew/bin:/Applications/Docker.app/Contents/Resources/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        PYTHON_BIN = "/opt/homebrew/opt/python@3.13/bin/python3.13"
        DEPLOY_REPOSITORY = "git@gitlab.alibaba-inc.com:youkun.yk/deploy.git"
        DEPLOY_TOOL_COMMIT = "3f18cb677bebc7cc7649d08b83e9cc4c64d8d6c7"
        DEPLOY_WAIT_TIMEOUT_SECONDS = "300"
        NACOS_SECRETS_DIR = "/Users/yuanzhan/Documents/Data/nacos/secrets"
        NACOS_DATA_DIR = "/Users/yuanzhan/Documents/Data/nacos/data"
        NACOS_LOGS_DIR = "/Users/yuanzhan/Documents/Data/nacos/logs"
    }

    stages {
        stage('Checkout') {
            steps {
                checkout scm
                script {
                    env.SOURCE_REVISION = sh(
                        returnStdout: true,
                        script: 'git rev-parse HEAD'
                    ).trim()
                    if (!(env.SOURCE_REVISION ==~ /[0-9a-f]{40}/)) {
                        error('SCM did not resolve an exact 40-character revision')
                    }
                    currentBuild.description = env.SOURCE_REVISION.take(12)
                }
                dir("${env.WORKSPACE}@tmp/deploy-tools") {
                    deleteDir()
                    sh '''
                        set -Eeuo pipefail
                        git init
                        git remote add origin "$DEPLOY_REPOSITORY"
                        git fetch --depth 1 origin "$DEPLOY_TOOL_COMMIT"
                        git checkout --detach FETCH_HEAD
                        test "$(git rev-parse HEAD)" = "$DEPLOY_TOOL_COMMIT"
                    '''
                }
            }
        }

        stage('Validate Host Contract') {
            steps {
                sh '''
                    set -Eeuo pipefail
                    test "$(id -u)" = 501
                    test -d "$NACOS_SECRETS_DIR"
                    test -d "$NACOS_DATA_DIR"
                    test -d "$NACOS_LOGS_DIR"
                    test -w "$NACOS_DATA_DIR"
                    test -w "$NACOS_LOGS_DIR"

                    expected_secrets=(
                        admin-password
                        auth-token-secret
                        database-password
                        server-identity-key
                        server-identity-value
                    )
                    for secret_name in "${expected_secrets[@]}"; do
                        secret_file="$NACOS_SECRETS_DIR/$secret_name"
                        test -f "$secret_file"
                        test -r "$secret_file"
                        test -s "$secret_file"
                        test "$(stat -f '%Lp' "$secret_file")" = 600
                    done
                    test "$(
                        find "$NACOS_SECRETS_DIR" -maxdepth 1 -type f | wc -l | xargs
                    )" = "${#expected_secrets[@]}"

                    docker version >/dev/null
                    docker compose version >/dev/null
                '''
            }
        }

        stage('Publish Image') {
            steps {
                sh '''
                    set -Eeuo pipefail
                    deploy_tools="${WORKSPACE}@tmp/deploy-tools"
                    result_dir="${WORKSPACE}@tmp/release-results"
                    mkdir -p "$result_dir"

                    "$deploy_tools/local/publish_image.sh" \
                        "$REGISTRY_HOST" \
                        "$WORKSPACE" \
                        nacos |
                        tee "$result_dir/nacos-publish.env"

                    cp "$result_dir/nacos-publish.env" "$WORKSPACE/nacos-publish.env"
                '''
                script {
                    env.APPLICATION_IMAGE = sh(
                        returnStdout: true,
                        script: "sed -n 's/^IMAGE_DIGEST_REF=//p' nacos-publish.env | tail -1"
                    ).trim()
                    if (!(env.APPLICATION_IMAGE ==~ /.+@sha256:[0-9a-f]{64}/)) {
                        error('Nacos image publish did not return a digest')
                    }
                }
            }
        }

        stage('Deploy Application') {
            steps {
                sh '''
                    set -Eeuo pipefail
                    "${WORKSPACE}@tmp/deploy-tools/deploy_image.sh" \
                        nacos \
                        "$WORKSPACE/compose.yaml" \
                        "$APPLICATION_IMAGE" \
                        "$REGISTRY_HOST"
                '''
            }
        }

        stage('Verify Runtime') {
            steps {
                sh '''
                    set -Eeuo pipefail
                    container_id="$(
                        docker ps \
                            --filter label=com.docker.compose.project=nacos \
                            --filter label=com.docker.compose.service=nacos \
                            --format '{{.ID}}' |
                            head -1
                    )"
                    test -n "$container_id"

                    configured_image="$(
                        docker inspect \
                            --format '{{.Config.Image}}' \
                            "$container_id"
                    )"
                    test "$configured_image" = "$APPLICATION_IMAGE"

                    deployed_revision="$(
                        docker inspect \
                            --format '{{index .Config.Labels "org.opencontainers.image.revision"}}' \
                            "$container_id"
                    )"
                    test "$deployed_revision" = "$SOURCE_REVISION"

                    configured_user="$(
                        docker inspect \
                            --format '{{.Config.User}}' \
                            "$container_id"
                    )"
                    test "$configured_user" = nacos

                    health_status="$(
                        docker inspect \
                            --format '{{.State.Health.Status}}' \
                            "$container_id"
                    )"
                    test "$health_status" = healthy

                    curl \
                        --fail \
                        --silent \
                        --show-error \
                        --connect-timeout 3 \
                        --max-time 10 \
                        http://127.0.0.1:8081/v3/console/health/readiness \
                        > runtime-health.json

                    "$PYTHON_BIN" -c "$(
                        printf '%s\n' \
                            'import json, sys' \
                            'from pathlib import Path' \
                            'payload = json.loads(Path("runtime-health.json").read_text(encoding="utf-8"))' \
                            'payload.get("code") == 0 or sys.exit("runtime readiness code is not successful")' \
                            'payload.get("data") == "ok" or sys.exit("runtime readiness data is not ok")'
                    )"
                '''
            }
        }
    }

    post {
        always {
            archiveArtifacts(
                artifacts: '*.json,*.env',
                allowEmptyArchive: true,
                fingerprint: true
            )
        }
    }
}
