#!/usr/bin/env bash
set -e

function setup() {
  BASEPATH="$(pwd)"
  cd $(git rev-parse --show-toplevel)
  # Load .env
  set -a
  _check_env
  [ -f .env ] && . .env
  set +a
  cd $BASEPATH

  export APP_CONTAINER=$(docker ps | grep "${PROJECT_NAME}-app" | egrep ".[a-z0-9]*" -o | head -1)
  export $(cat .env | xargs)
}

function isFunction() { [[ "$(declare -Ff "$1")" ]]; }

function main() {
  setup
  if [[ -z $1 ]]; then
    help
  else
    if isFunction $1; then
      COMMAND=($@)
      PARAMETERRS=${COMMAND[@]:1}
      eval "$1 \"$PARAMETERRS\""
    else
      echo "Command '$1' not found"
    fi
  fi
}

function cli() {
  if [[ ! -z $@ ]]; then
    docker exec ${APP_CONTAINER} /bin/bash -c "$@"
  else
    echo "### CLI - ${PROJECT_NAME} ###"
    docker exec -it ${APP_CONTAINER} /bin/bash
  fi
}

function test-all() {
  test-code
  test-functional
}

function test-code() {
  start-test
  mkdir -p test-reports/
  chmod 777 test-reports/
  echo "[PHPCS]: Custom modules"
  composer "coder-check /var/www/project/docroot/modules/custom"
  echo "[PHPSTAN]: Custom modules"
  composer "code-analyse /var/www/project/docroot/modules/custom"
  echo "[PHPUNIT]: Custom modules"
  cli bin/phpunit /var/www/project/docroot/modules/custom
}

function test-code-junit() {
  start-test
  mkdir -p test-reports/
  chmod 777 test-reports/
  echo "[PHPCS]: Custom modules"
  composer "coder-check-junit /var/www/project/docroot/modules/custom"
  echo "[PHPSTAN]: Custom modules"
  composer "code-analyse-junit /var/www/project/docroot/modules/custom" >test-reports/phpstan-custom-modules.xml
  echo "[PHPUNIT]: Custom modules"
  cli bin/phpunit /var/www/project/docroot/modules/custom --log-junit test-reports/phpunit-custom.xml
}

function test-code-contrib() {
  start-test
  mkdir -p test-reports/
  chmod 777 test-reports/
  echo "[PHPSTAN]: Contrib profiles"
  composer "code-analyse-junit /var/www/project/docroot/profiles/contrib" >test-reports/phpstan-contrib-profiles.xml
  echo "[PHPUNIT]: Contrib Profiles"
  cli bin/phpunit /var/www/project/docroot/profiles/contrib --log-junit test-reports/phpunit.xml
}

function test-functional() {
  start-test
  mkdir -p test-reports/
  _update_translations
  echo "Executing behat"
  cli "bin/behat --format=pretty --format=junit --out=std --out=test-reports -c testing/behat/behat.dist.yml --suite=default --strict --colors --tags=$1"
}

function test-install() {
  start-test
  mkdir -p test-reports/
  echo "Executing behat"
  cli "bin/behat --format=pretty --format=junit --out=std --out=test-reports -c testing/behat/behat.dist.yml  --strict --colors"
  _update_translations
}

function help() {
  echo "### nrwGOV - Scripts ###"
  echo "test    - Run all tests"
  echo "cli     - Run cli"
  echo "start   - Start environment"
  echo "stop    - Stop environment"
  echo "log     - Show logs"
  echo "setupdb - Config import & Database updates & locale updates"
  echo "import  - Import database <path to gzipped sql dump> (relative to sync-path)"
  echo "install - Installs scripts globally (/usr/local/bin/ppd)"
  echo "help    - ..."
  echo "########################"
}

function setupdb() {
  drush updb -y
  drush cim -y
  drush locale-check
  drush locale-update
}

function log() {
  docker-compose logs
}

function build() {
  compose build
}

function start() {
  _check_env
  _check_network
  _check_traefik
  _check_dns
  compose up -d
  _check_for_composer_install
  echo "open http://${PROJECT_NAME}.${DOMAIN_SUFFIX} in browser"
}

function clamav() {
    cli "/etc/init.d/clamav-daemon $1"
}

function status() {
  drush status
}

function compose() {
  if [[ "$OSTYPE" == "linux-gnu" ]]; then
    docker-compose -f docker-compose.yml -f docker-compose.linux.override.yml $@
  elif [[ "$OSTYPE" == "darwin"* ]]; then
    docker-compose -f docker-compose.yml -f docker-compose.mac.override.yml $@
  fi
}

function start-test() {
  compose -f docker-compose.testing.yml up -d
}

function stop() {
  compose stop
}

function checkout() {
  git reset --hard && git checkout $1 -f && git clean -fd
  git pull origin $1
  (cd $(git rev-parse --show-toplevel)/${SYNC_PATH} && composer install && import /dump/${DUMP_NAME})
  setupdb
  echo "Environment ready! Branch: $1"
}

function import() {
  local IMPORT_NAME="${1:-/dump/${DUMP_NAME}}"
  drush sql-drop -y
  cli "zcat $IMPORT_NAME | bin/drush sql:cli"
  echo "Successfully imported: $IMPORT_NAME"
  setupdb
}

function install() {
  sudo cp "$(pwd)/$0" /usr/local/bin/ppd
  echo "Installed $0 try out 'ppd'"
}

drush() {
  cli "bin/drush $@"
}

composer() {
  cli "bin/composer $@"
}

_update_translations() {
  echo "### Update translations"
  drush locale:check
  drush locale:update
  echo "### Clear cache"
  drush cr
}

_check_network() {
  NETWORK="$(docker network ls | grep web || true)"
  if [[ ! $NETWORK ]]; then
    docker network create web
    echo "Created web network"
  fi
}

_check_traefik() {
  if [ ! -d ~/traefik ]; then
    git clone git@bitbucket.org:publicplan/local-dev-traefik.git ~/traefik
    cp ~/traefik/.env.dist ~/traefik/.env
  fi
  (cd ~/traefik && docker-compose up -d)
}

_check_dns() {
  if [[ "$OSTYPE" == "darwin"* ]]; then
    HASENTRY="$(cat /etc/hosts | grep ${PROJECT_NAME}.${DOMAIN_SUFFIX} || true)"
    if [[ ! $HASENTRY ]]; then
      sudo sh -c 'echo "127.0.0.1	${PROJECT_NAME}.${DOMAIN_SUFFIX}" >> /private/etc/hosts'
      dscacheutil -flushcache || true
      echo "Added ${PROJECT_NAME}.${DOMAIN_SUFFIX} to /private/etc/hosts"
    fi
  fi
}

_check_env() {
  if [[ ! -f ".env" ]]; then
    cp .env.dist .env
    echo "Copied default .env"
  fi
  if [[ "$OSTYPE" == "darwin"* ]]; then
    if [[ ! -f "/tmp/agent.sock" ]]; then
      ln -sf $SSH_AUTH_SOCK /tmp/agent.sock
      echo "Linked ssh-agent"
    fi
  fi
}

_check_for_composer_install() {
  if [[ $INSTALL_COMPOSER_ON_STARTUP ]]; then
    cli 'if [[ ! -d ./vendor ]]; then echo "Installing dependencies... " && composer i; fi'
    echo "Installed dependencies"
  fi
}

main $1 $2
