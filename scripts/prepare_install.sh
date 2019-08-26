#!/bin/bash

ATL_GENERATE_PASSWORD_SCRIPT="print(com.atlassian.security.password.DefaultPasswordEncoder.getDefaultInstance().encodePassword(arguments[0]));"
ATL_GENERATE_SERVER_ID_SCRIPT="print((new com.atlassian.license.DefaultSIDManager()).generateSID());"

ATL_TEMP_DIR="/tmp"
ATL_JIRA_VARFILE="${ATL_TEMP_DIR}/jira.varfile"
ATL_MSSQL_DRIVER_URL="https://repo1.maven.org/maven2/com/microsoft/sqlserver/mssql-jdbc/6.1.0.jre8/mssql-jdbc-6.1.0.jre8.jar"
ATL_POSTGRES_DRIVER_URL="http://central.maven.org/maven2/org/postgresql/postgresql/9.4.1211/postgresql-9.4.1211.jar"

function atl_log {
  local scope=$1
  local msg=$2
  echo "[${scope}]: ${msg}"
}

function atl_error {
  atl_log "$1" "$2" >&2
}

function log {
  atl_log "${FUNCNAME[1]}" "$1"
}

function error {
  atl_error "${FUNCNAME[1]}" "$1"
  exit 1
}

function tune_tcp_keepalive_for_azure {
  # Values taken from https://docs.microsoft.com/en-us/sql/connect/jdbc/connecting-to-an-azure-sql-database
  # Windows values are milliseconds, Linux values are seconds

  atl_log tune_tcp_keepalive_for_azure "Tuning TCP KeepAlive settings for Azure..."
  atl_log tune_tcp_keepalive_for_azure "Old values: "$'\n'"$(sysctl net.ipv4.tcp_keepalive_time net.ipv4.tcp_keepalive_intvl net.ipv4.tcp_keepalive_probes)"

  local new_values="$(sysctl -w \
    net.ipv4.tcp_keepalive_time=30 \
    net.ipv4.tcp_keepalive_intvl=1 \
    net.ipv4.tcp_keepalive_probes=10 \
        | tee -a /etc/sysctl.conf)"
  atl_log tune_tcp_keepalive_for_azure "New values: "$'\n'"${new_values}"
}

function preserve_installer {
  local jira_version=$(cat version)
  local jira_installer="atlassian-${ATL_JIRA_PRODUCT}-${jira_version}-x64.bin"

  atl_log preserve_installer "preserving ${ATL_JIRA_PRODUCT} installer ${jira_installer} and metadata"
  cp installer ${ATL_JIRA_SHARED_HOME}/${jira_installer}
  cp version ${ATL_JIRA_SHARED_HOME}/$ATL_JIRA_PRODUCT.version
  atl_log preserve_installer "${ATL_JIRA_PRODUCT} installer ${jira_installer} and metadata has been preserved"
}

function download_installer {

  local jira_version=${ATL_JIRA_PRODUCT_VERSION}
  echo "${ATL_JIRA_PRODUCT_VERSION}" > version
  atl_log download_installer "Going to use ${ATL_JIRA_PRODUCT} with version: ${ATL_JIRA_PRODUCT_VERSION}"

  if [[ ${ATL_JIRA_PRODUCT_VERSION} == 'latest' ]]
  then
    # Get latest version from the special /latest url.
    local jira_version_file_url="${ATL_JIRA_RELEASES_BASE_URL}/${ATL_JIRA_PRODUCT}/latest"
    atl_log download_installer "Downloading installer description from ${jira_version_file_url}"

    if ! curl -L -f --silent "${jira_version_file_url}" \
       -o "version" 2>&1
    then
      atl_log download_installer "Could not download installer description from ${jira_version_file_url}"
      exit 1
    fi

    local jira_version=$(cat version)
  fi
  

  local jira_installer="atlassian-${ATL_JIRA_PRODUCT}-${jira_version}-x64.bin"
  [ -n "${ATL_JIRA_CUSTOM_DOWNLOAD_URL}" ] && local jira_installer_url="${ATL_JIRA_CUSTOM_DOWNLOAD_URL}/${jira_installer}" || local jira_installer_url="${ATL_JIRA_RELEASES_BASE_URL}/${ATL_JIRA_PRODUCT}/${jira_installer}"
  atl_log download_installer "Downloading ${ATL_JIRA_PRODUCT} installer from ${jira_installer_url}"

  if ! curl -L -f --silent "${jira_installer_url}" \
       -o "installer" 2>&1
  then
    atl_log download_installer "Could not download ${ATL_JIRA_PRODUCT} installer from ${jira_installer_url}"
    exit 1
  fi
}

function install_pacapt {
  wget -O /usr/local/bin/pacapt https://github.com/icy/pacapt/raw/ng/pacapt
  sudo chmod 755 /usr/local/bin/pacapt
}

function install_redhat_epel_if_needed {
  if [[ -n ${IS_REDHAT} ]]
  then
	  wget https://dl.fedoraproject.org/pub/epel/epel-release-latest-7.noarch.rpm
	  yum install -y ./epel-release-latest-*.noarch.rpm
  fi
}

function install_core_dependencies {
  # Seeing consistent issues on Azure where apt/yum not get full list of azure repos and then not able to install dependencies.
  pacapt update --noconfirm
  sleep 5
  pacapt update --noconfirm

  # Packages done on different lines as yum command will fail if unknown package defined. Some future proofing.
  pacapt install --noconfirm cifs-utils
  pacapt install --noconfirm curl
  pacapt install --noconfirm rsync
  pacapt install --noconfirm netcat
  pacapt install --noconfirm jq

  # If any of the commands fail above due to locks etc it'll fail at one above.
  if [ "$?" -ne "0" ]; then
      error "Error downloading core dependencies!"
  fi
  
  # nc/nmap-ncat needed on RHEL jumpbox for SSH proxying
  [ -n "${IS_REDHAT}" ] && pacapt install --noconfirm java-1.8.0-openjdk-headless nc || pacapt install --noconfirm openjdk-8-jre-headless
}

function prepare_password_generator {
  echo "${ATL_GENERATE_PASSWORD_SCRIPT}" > generate-password.js
}

function install_password_generator {
  atl_log install_password_generator "Downloading Password Generator Jars"
  JARS="https://packages.atlassian.com/mvn/maven-external/com/atlassian/extras/atlassian-extras/3.3.0/atlassian-extras-3.3.0.jar \
	  http://central.maven.org/maven2/commons-lang/commons-lang/2.6/commons-lang-2.6.jar \
	  http://central.maven.org/maven2/commons-codec/commons-codec/1.9/commons-codec-1.9.jar \
	  https://packages.atlassian.com/mvn/maven-external/com/atlassian/security/atlassian-password-encoder/3.2.3/atlassian-password-encoder-3.2.3.jar \
    http://central.maven.org/maven2/org/liquibase/liquibase-core/3.5.3/liquibase-core-3.5.3.jar \
    http://central.maven.org/maven2/org/bouncycastle/bcprov-jdk15on/1.50/bcprov-jdk15on-1.50.jar"

  for aJar in $(echo $JARS)
  do
    if [[ ! -f $(basename $aJar) ]]
    then
      curl -LO ${aJar}
    fi
  done
}

function run_password_generator {
  jjs -cp atlassian-password-encoder-3.2.3.jar:commons-lang-2.6.jar:commons-codec-1.9.jar:bcprov-jdk15on-1.50.jar generate-password.js -- $1
  if [ "$?" -ne "0" ]; then
      error "Error running the password generator!"
  fi
}

function prepare_server_id_generator {
  log "Preparing Server Id generation script"
  echo "${ATL_GENERATE_SERVER_ID_SCRIPT}" > generate-serverid.js
  log "Server Id generation script is ready"
}

function generate_server_id {
  jjs -cp atlassian-extras-3.3.0.jar generate-serverid.js
  if [ "$?" -ne "0" ]; then
      error "Error running the server id generator!"
  fi
}

# issue_signed_request
#   <verb> - GET/PUT/POST
#   <url> - the resource uri to actually post
#   <canonical resource> - the canonicalized resource uri
# see https://msdn.microsoft.com/en-us/library/azure/dd179428.aspx for details
function issue_signed_request {
  request_method="$1"
  request_url="$2"
  canonicalized_resource="/${STORAGE_ACCOUNT}/$3"
  access_key="$4"
  
  request_date=$(TZ=GMT date "+%a, %d %h %Y %H:%M:%S %Z")
  storage_service_version="2015-04-05"
  authorization="SharedKey"
  file_store_url="file.core.windows.net"
  full_url="https://${STORAGE_ACCOUNT}.${file_store_url}/${request_url}"
  
  x_ms_date_h="x-ms-date:$request_date"
  x_ms_version_h="x-ms-version:$storage_service_version"
  canonicalized_headers="${x_ms_date_h}\n${x_ms_version_h}\n"
  content_length_header="Content-Length:0"

  string_to_sign="${request_method}\n\n\n\n\n\n\n\n\n\n\n\n${canonicalized_headers}${canonicalized_resource}"
  decoded_hex_key="$(echo -n "${access_key}" | base64 -d -w0 | xxd -p -c256)"
  signature=$(printf "$string_to_sign" | openssl dgst -sha256 -mac HMAC -macopt "hexkey:$decoded_hex_key" -binary |  base64 -w0)
  authorization_header="Authorization: $authorization ${STORAGE_ACCOUNT}:$signature"
  
  curl -sw "/status/%{http_code}/\n" \
       -X $request_method \
       -H "$x_ms_date_h" \
       -H "$x_ms_version_h" \
       -H "$authorization_header" \
       -H "$content_length_header" \
       $full_url 
}

function validate {
  if [ ! "$1" ];
  then
    error "response was null"
  fi
  
  if [[ $(echo ${1} | grep -o "/status/2") || $(echo ${1} | grep -o "/status/409") ]];
  then
    # response is valid or share already exists, ignore
    return
  else
    # other or unknown status
    if [ $(echo ${1} | grep -o "/status/") ];
    then
      error "response was not valid: ${1}"
    else
      error "no response code found: ${1}"
    fi
  fi
}

function list_shares {
  local access_key="$1"
  response="$(issue_signed_request GET ?comp=list "\ncomp:list" "${access_key}")"
  echo ${response}
}

function create_share {
  log "creating share ${ATL_JIRA_SHARED_HOME_NAME}"

  local url="${ATL_JIRA_SHARED_HOME_NAME}?restype=share"
  local res="${ATL_JIRA_SHARED_HOME_NAME}\nrestype:share"
  
  # test whether share exists already
  response=$(list_shares "${STORAGE_KEY}")
  validate "$response"
  exists=$(echo ${response} | grep -c "<Share><Name>${ATL_JIRA_SHARED_HOME_NAME}</Name>")
  
  if [ ${exists} -eq 0 ];
  then
    # create share
    response=$(issue_signed_request "PUT" ${url} ${res} "${STORAGE_KEY}")
    validate "${response}"
  fi
}

function mount_share {
  local persist="$1"
  local uid=${2:-0}
  local gid=${3:-0}
  creds_file="/etc/cifs.${ATL_JIRA_SHARED_HOME_NAME}"
  mount_options="vers=3.0,uid=${uid},gid=${gid},dir_mode=0750,file_mode=0640,credentials=${creds_file}"
  mount_share="//${STORAGE_ACCOUNT}.file.core.windows.net/${ATL_JIRA_SHARED_HOME_NAME}"
  
  log "creating credentials at ${creds_file}"
  echo "username=${STORAGE_ACCOUNT}" >> ${creds_file}
  echo "password=${STORAGE_KEY}" >> ${creds_file}
  chmod 600 ${creds_file}
  
  log "mounting share ${mount_share} at ${ATL_JIRA_SHARED_HOME} with options: ${mount_options}"
  
  if [ $(cat /etc/mtab | grep -o "${ATL_JIRA_SHARED_HOME}") ];
  then
    log "location ${ATL_JIRA_SHARED_HOME} is already mounted"
    return 0
  fi
  
  [ -d "${ATL_JIRA_SHARED_HOME}" ] || mkdir -p "${ATL_JIRA_SHARED_HOME}"
  mount -t cifs ${mount_share} ${ATL_JIRA_SHARED_HOME} -o ${mount_options}
  
  if [ ! $(cat /etc/mtab | grep -o "${ATL_JIRA_SHARED_HOME}") ];
  then
    error "mount failed"
  fi
  
  if [ ${persist} ];
  then
    # create a backup of fstab
    cp /etc/fstab /etc/fstab_backup
    
    # update /etc/fstab
    echo ${mount_share} ${ATL_JIRA_SHARED_HOME} cifs ${mount_options} >> /etc/fstab
    
    # test that mount works
    umount ${ATL_JIRA_SHARED_HOME}
    mount ${ATL_JIRA_SHARED_HOME}
    
    if [ ! $(cat /etc/mtab | grep -o "${ATL_JIRA_SHARED_HOME}") ];
    then
      # revert changes
      cp /etc/fstab_backup /etc/fstab
      error "/etc/fstab was not configured correctly, changes reverted"
    fi
  fi

  log "Waiting a bit to make sure that share is readable"
  sleep 10s
  sync
  sleep 10s
  log "Waiting completed"
}

function prepare_share {
  create_share
  mount_share 1
}

function hydrate_shared_config {
  export SERVER_PROXY_NAME="${SERVER_CNAME:-${SERVER_AZURE_DOMAIN}}"
  export DB_TRUSTED_HOST=$(get_trusted_dbhost)
  export DB_SCRIPT_NAME_LOC=$(ls -C1 *db.sql.template | sed 's/\.template$//')

  case $DB_TYPE in
     sqlserver)
         export DB_CONFIG_TYPE="mssql"
         export DB_DRIVER_JAR="mssql-jdbc-6.1.0.jre8.jar"
         export DB_DRIVER_CLASS="com.microsoft.sqlserver.jdbc.SQLServerDriver"
         export DB_JDBCURL="jdbc:sqlserver://${DB_SERVER_NAME}:${DB_PORT};database=${DB_NAME};encrypt=true;trustServerCertificate=false;hostNameInCertificate=${DB_TRUSTED_HOST}"
         export DB_USER_LIQUIBASE="${DB_USER}@${DB_SERVER_NAME}"
         ;;
     postgres)
         export DB_CONFIG_TYPE="postgres72"
         export DB_DRIVER_JAR="postgresql-9.4.1211.jar"
         export DB_DRIVER_CLASS="org.postgresql.Driver"
         export DB_USER="$DB_USER@$(echo ${DB_SERVER_NAME} | cut -d '.' -f1)"
         export DB_JDBCURL="jdbc:postgresql://${DB_SERVER_NAME}:${DB_PORT}/${DB_NAME}?ssl=true"
         export DB_USER_LIQUIBASE="${DB_USER}"
         ;;
     *)
         error "Unsupported DB Type: ${DB_TYPE}"
         ;;
  esac

  atl_log hdyrate_shared_config "Created DB_JDBCURL=${DB_JDBCURL}"

  local template_files=(dbconfig.xml.template server.xml.template ApplicationInsights.xml.template jira-collectd.conf.template databaseChangeLog.xml.template)
  local output_file=""
  for template_file in ${template_files[@]};
  do
    output_file=`echo "${template_file}" | sed 's/\.template$//'`
    cat ${template_file} | python hydrate_jira_config.py > ${output_file}
    atl_log hdyrate_shared_config "Hydrated '${template_file}' into '${output_file}'"
  done
}

function copy_artefacts {
  local excluded_files=(std* version installer *.jar prepare_install.sh *.py *.sh *.template *.sql *.js *.xsl *.rpm)

  local exclude_rules=""
  for file in ${excluded_files[@]};
  do
    exclude_rules="--exclude ${file} ${exclude_rules}"
  done

  rsync -av ${exclude_rules} * ${ATL_JIRA_SHARED_HOME}
}

function hydrate_db_dump {
  export USER_ENCRYPTION_METHOD="atlassian-security"
  export USER_PASSWORD=`run_password_generator ${USER_CREDENTIAL}`
  export USER_FIRSTNAME=`echo ${USER_FULLNAME} | cut -d ' ' -f 1`
  export USER_LASTNAME=`echo ${USER_FULLNAME} | cut -d ' ' -f 2-`
  export USER_FIRSTNAME_LOWERCASE=`echo ${USER_FULLNAME_LOWERCASE} | cut -d ' ' -f 1`
  export USER_LASTNAME_LOWERCASE=`echo ${USER_FULLNAME_LOWERCASE} | cut -d ' ' -f 2-`
  export SERVER_ID=`generate_server_id`
  export DB_USER=`echo ${DB_USER} | cut -d '@' -f 1`

  log "Generated server id [${SERVER_ID}]"

  log "Prepare database dump [user=${USER_NAME}, password=${USER_PASSWORD}, credential=${USER_CREDENTIAL}]"

  local template_file=$(ls -C1 *db.sql.template)
  local output_file=`echo "${template_file}" | sed 's/\.template$//'`

  cat ${template_file} | python hydrate_jira_config.py > ${output_file}
  log "Hydrated '${template_file}' into '${output_file}'"
}

function prepare_database {
  atl_log prepare_database "Installing liquibase"
  atl_log prepare_database "ready to hydrate db dump"
  hydrate_db_dump
}

function get_trusted_dbhost {
  local host=$(echo "${DB_SERVER_NAME}" | cut -d . -f 2-)
  echo "*.${host}"
}

function apply_database_dump {
  java -jar liquibase-core-3.5.3.jar \
    --classpath="${DB_DRIVER_JAR}" \
    --driver=${DB_DRIVER_CLASS} \
    --url="${DB_JDBCURL}" \
    --username="${DB_USER_LIQUIBASE}" \
    --password="${DB_PASSWORD}" \
    --logLevel=info \
    --changeLogFile=databaseChangeLog.xml \
    update
  
  if [ "$?" -ne "0" ]; then
    copy_artefacts
    error "Liquibase dump failed with and error. Check logs and rectify!!"
  else
    atl_log apply_database_dump "Liquibase has been successfully executed"
  fi
}

function prepare_env {
  for var in `printenv | grep _ATL_ENV_DATA`; do log $var; done
  for var in `printenv | grep _ATL_ENV_DATA | cut -d "=" -f 1`; \
    do printf '%s\n' "${!var}" | \
        base64 --decode | \
        jq -r '[.[] | { name, escaped_value: .value | @sh }] | .[]| "export " + .name + "=" + "$(echo " + .escaped_value + ")"' \
           >> setenv.sh; \
    done

  atl_log prepare_env "Using BaseURL of ${3}://${2}"
  echo "export STORAGE_KEY='${1}'" >> setenv.sh
  echo "export BASEURL='${3}://${2}'" >> setenv.sh
}

function prepare_varfile {
  atl_log prepare_varfile "Preparing var file"

  cat <<EOT >> "${ATL_JIRA_VARFILE}"
launch.application\$Boolean=false
rmiPort\$Long=8005
app.jiraHome=${ATL_JIRA_HOME}
app.install.service\$Boolean=true
existingInstallationDir=${ATL_JIRA_INSTALL_DIR}
sys.confirmedUpdateInstallationString=false
sys.languageId=en
sys.installationDir=${ATL_JIRA_INSTALL_DIR}
executeLauncherAction\$Boolean=true
httpPort\$Long=8080
portChoice=default
executeLauncherAction\$Boolean=false
EOT
  
  atl_log prepare_varfile "varfile is ready:"
  printf "`cat ${ATL_JIRA_VARFILE}`\n"
}

# Copies the proper version of JIRA's installer from shared home location
# into temp directory
# JIRA's version to install is specified by version file
# So in theory we can have multiple installers in home directory.
# Kinda forward thinking about upgrades and ZDU
# Also it almost straight copy-paste from our AWS scripts
function restore_installer {
  local jira_version=$(cat ${ATL_JIRA_SHARED_HOME}/${ATL_JIRA_PRODUCT}.version)
  local jira_installer="atlassian-${ATL_JIRA_PRODUCT}-${jira_version}-x64.bin"

  atl_log restore_installer "Using existing installer ${jira_installer} from ${ATL_JIRA_SHARED_HOME} mount"

  local installer_path="${ATL_JIRA_SHARED_HOME}/${jira_installer}"
  local installer_target="${ATL_TEMP_DIR}/installer"
  
  if [[ -f ${installer_path} ]]; then
    cp ${installer_path} "${installer_target}"
    chmod 0700 "${installer_target}"
  else
    local msg="${ATL_JIRA_PRODUCT} installer ${jira_installer} has been requested but unable to locate it in ${ATL_JIRA_SHARED_HOME}"
    atl_log restore_installer "${msg}"
    error "${msg}"
  fi

  atl_log restore_installer "Restoration of ${ATL_JIRA_PRODUCT} installer ${jira_installer} has been completed"
}

function ensure_readable {
  local path=$1

  local timeout=300
  local interval=10

  local start=$(date +%s)

  log "Making sure to be able to read [file=${path}]"
  while true; do
    if [[ ! -f "${path}" ]]; then 
      local end=$(date +%s)
      if [[ $(($end - $start)) -gt $timeout ]]; then
        error "Failed to ensure to be able to read [file=${path}]"
      else
        log "Unable to read [file=${path}], retrying..."
        log "$(($timeout - ($end - $start))) seconds left"
        sleep ${interval}s
        sync
      fi
    else
      return 0
    fi
  done
}

# Check if we already have installer in shared home and restores it if we do
# otherwise just downloads the installer and puts it into shared home
function prepare_installer {
  atl_log prepare_install "Checking if installer has been downloaded aready"
  ensure_readable "${ATL_JIRA_SHARED_HOME}/server.xml"
  if [[ -f ${ATL_JIRA_SHARED_HOME}/$ATL_JIRA_PRODUCT.version ]]; then
    atl_log prepare_installer "Detected installer, restoring it"
    restore_installer
  else
    atl_log prepare_installer "No installer has been found, downloading..."
    download_installer
    preserve_installer
    restore_installer
  fi

  atl_log prepare_installer "Installer is ready!"
}

# Check if fontconfig has been installed.
# Adoptopenjdk8 has a known bug with fontconfig missing, which will cause installer to fail
# Details see https://github.com/AdoptOpenJDK/openjdk-build/issues/693
function prepare_fontconfig {
  log "Installing fontconfig package..."
  apt update && apt install -y fontconfig

  log "Font config is ready!"
}

function perform_install {
  atl_log perform_install "Ready to perform installation"

  atl_log perform_install "Checking if ${ATL_JIRA_PRODUCT} has already been installed"
  if [[ -d "${ATL_JIRA_INSTALL_DIR}" ]]; then
    local msg="${ATL_JIRA_PRODUCT} install directory ${ATL_JIRA_INSTALL_DIR} already exists - aborting installation"
    atl_log perform_install "${msg}"
    error "${msg}"
  fi

  atl_log perform_install "Creating ${ATL_JIRA_PRODUCT} install directory"
  mkdir -p "${ATL_JIRA_INSTALL_DIR}"

  atl_log perform_install "Installing ${ATL_JIRA_PRODUCT} to ${ATL_JIRA_INSTALL_DIR}"
  "${ATL_TEMP_DIR}/installer" -q -varfile "${ATL_JIRA_VARFILE}" 2>&1
  atl_log perform_install "Installed ${ATL_JIRA_PRODUCT} to ${ATL_JIRA_INSTALL_DIR}"

  atl_log perform_install "Cleaning up..."
  rm -rf "${ATL_TEMP_DIR}"/installer* 2>&1

  chown -R jira:jira "${ATL_JIRA_INSTALL_DIR}"

  atl_log perform_install "${ATL_JIRA_PDORUCT} installation completed"
}

function install_jdbc_drivers {
  local install_location="${1:-${ATL_JIRA_INSTALL_DIR}/lib}"

  for jarURL in $(echo $ATL_MSSQL_DRIVER_URL $ATL_POSTGRES_DRIVER_URL)
  do
     atl_log install_jdbc_drivers "Downloading JDBC driver from ${jarURL}"
     curl -O "${jarURL}"

     atl_log install_jdbc_drivers "Copying JDBC driver to ${install_location}"
     cp -fp $(basename $(echo ${jarURL})) "${install_location}"
  done

  atl_log install_jdbc_drivers 'JDBC drivers has been copied.'
}

function install_appinsights {
  atl_log install_appinsights "Installation MS App Insights"
  atl_log install_appinsights "Have AppInsights Key? |${APPINSIGHTS_INSTRUMENTATION_KEY}|"
  if [ -n "${APPINSIGHTS_INSTRUMENTATION_KEY}" ]
  then
     atl_log install_appinsights "Installing App Insights"
     pacapt install --noconfirm xsltproc
     download_appinsights_jars ${ATL_JIRA_INSTALL_DIR}/atlassian-jira/WEB-INF/lib

     cp -fp ${ATL_JIRA_INSTALL_DIR}/atlassian-jira/WEB-INF/web.xml ${ATL_JIRA_INSTALL_DIR}/atlassian-jira/WEB-INF/web.xml.orig
     xsltproc -o ${ATL_JIRA_INSTALL_DIR}/atlassian-jira/WEB-INF/web.xml ./appinsights_transform_web_xml.xsl ${ATL_JIRA_INSTALL_DIR}/atlassian-jira/WEB-INF/web.xml

     cp -fp ${ATL_JIRA_SHARED_HOME}/ApplicationInsights.xml ${ATL_JIRA_INSTALL_DIR}/atlassian-jira/WEB-INF/classes

     atl_log install_appinsights "Switching on Jira JMX"
     echo "jira.monitoring.jmx.enabled=true" >> ${ATL_JIRA_HOME}/jira-config.properties

     cp -fp ${ATL_JIRA_INSTALL_DIR}/bin/setenv.sh ${ATL_JIRA_INSTALL_DIR}/bin/setenv.sh.orig
     sed 's/export CATALINA_OPTS/CATALINA_OPTS="${CATALINA_OPTS} -Dcom.sun.management.jmxremote -Dcom.sun.management.jmxremote.port=9999 -Dcom.sun.management.jmxremote.authenticate=false -Dcom.sun.management.jmxremote.ssl=false"\nexport CATALINA_OPTS/' ${ATL_JIRA_INSTALL_DIR}/bin/setenv.sh.orig > ${ATL_JIRA_INSTALL_DIR}/bin/setenv.sh
  fi
}

function check_collectd_java_linking {
  # https://github.com/collectd/collectd/issues/635
  # Applied to both RHEL 7.5, Ubuntu 18.04 (but not 16.04)
  [ -n "$(ldd /usr/lib/collectd/java.so | grep 'not found')" ] && atl_log check_collectd_java_linking "CollectD Java linking error found!!"
}

function install_appinsights_collectd {
  # Have moved collectd to run after Jira startup - doesn't start up well with all the mounting/remounting/Jira not being up.
  if [ -n "${APPINSIGHTS_INSTRUMENTATION_KEY}" ]
  then
    atl_log install_appinsights_collectd "Configuring collectd to publish Jira JMX"
    if [[ -n ${IS_REDHAT} ]]
    then
      # https://bugs.centos.org/view.php?id=15495
      pacapt install --noconfirm install collectd collectd-generic-jmx.x86_64 collectd-java.x86_64 collectd-sensors.x86_64 collectd-rrdtool.x86_64 glib2.x86_64
      ln -sf /usr/lib64/collectd /usr/lib/collectd

      # https://github.com/collectd/collectd/issues/635
      ln -sf /etc/alternatives/jre/lib/amd64/server/libjvm.so /lib64
      check_collectd_java_linking
      cp -fp ${ATL_JIRA_SHARED_HOME}/jira-collectd.conf /etc/collectd.d
      chmod +r /etc/collectd.d/*.conf

      # Disable SELINUX - prevents Collectd logfile writing to /var/log
      # https://serverfault.com/questions/797039/collectd-permission-denied-to-log-file
      setenforce 0
      sed --in-place=.bak 's/SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config
    else
      pacapt install --noconfirm collectd
      ln -sf /usr/lib/jvm/java-8-openjdk-amd64/jre/lib/amd64/server/libjvm.so /lib/x86_64-linux-gnu/
      check_collectd_java_linking
      cp -fp ${ATL_JIRA_SHARED_HOME}/jira-collectd.conf /etc/collectd/collectd.conf
      chmod +r /etc/collectd/collectd.conf
    fi

    # JAXB now required for JDK > 8 for AppInsights + Collectd. Ubuntu Collectd now compiled/using JDK 11 as no choice
    curl -LO http://central.maven.org/maven2/javax/xml/bind/jaxb-api/2.3.1/jaxb-api-2.3.1.jar

    atl_log install_appinsights_collectd "Copying collectd appinsights jar to /usr/share/collectd/java"
    cp -fp applicationinsights-collectd*.jar jaxb-api-2.3.1.jar /usr/share/collectd/java/

    atl_log install_appinsights_collectd "Starting collectd..."
    systemctl start collectd

    # Bouncing collectd - cgroups issue with Azure wagent
    sleep 5
    systemctl restart collectd
  fi
}

function download_appinsights_jars {
  atl_log download_appinsights_jars "Downloading MS AppInsight Jars"
  JARS="applicationinsights-core-${APPINSIGHTS_VER}.jar applicationinsights-web-${APPINSIGHTS_VER}.jar applicationinsights-collectd-${APPINSIGHTS_VER}.jar"
  for aJar in $(echo $JARS)
  do
     curl -LO https://github.com/Microsoft/ApplicationInsights-Java/releases/download/${APPINSIGHTS_VER}/${aJar}
     if [ $aJar != "applicationinsights-collectd-${APPINSIGHTS_VER}.jar" ]
     then
          atl_log download_appinsights_jars "Copying appinsights jar: ${aJar} to ${1}"
          cp -fp ${aJar} ${1}
     fi
  done
}

function configure_cluster {
  atl_log configure_cluster "Configuring JIRA cluster node"

  local node_id=$(curl --silent -H Metadata:true "http://169.254.169.254/metadata/instance?api-version=2017-04-02" | jq -r ".compute.vmId")

  cat <<EOT >> "${ATL_JIRA_HOME}/cluster.properties"
# This ID must be unique across the cluster
jira.node.id = ${node_id}

# The location of the shared home directory for all JIRA nodes
jira.shared.home = ${ATL_JIRA_SHARED_HOME}
EOT
  atl_log configure_cluster "Cluster has been configured [node_id=${node_id}, shared_home=${ATL_JIRA_SHARED_HOME}]"
}

function get_jira_ram {
  for mem in `free -m | grep "Mem:" | sed 's/\s\+/|/g' | cut -d '|' -f2`; do echo $((mem/100*75)); done
}

function get_default_jira_ram {
  cat /opt/atlassian/jira/bin/setenv.sh | grep JVM_MAXIMUM_MEMORY= | cut -d '"' -f 2
}

function configure_jira_ram {
  atl_log configure_jira_ram "Adjusting JIRA's RAM settings to match the VM"
  local default="$(get_default_jira_ram)"
  local ram="$(get_jira_ram)m"
  local file='setenv.sh'
  local path="${ATL_JIRA_INSTALL_DIR}/bin/${file}"
  atl_log configure_jira_ram "Setting [${path}] to have [${ram}] instead of [${default}]"
  sed -i "s/${default}/${ram}/g" "${path}"
}

function configure_jira {
  atl_log configure_jira "Ready to configure JIRA"

  local jira_configs=(dbconfig.xml)
  local ram=`get_jira_ram`

  for cfg in ${jira_configs}; do
    atl_log configure_jira "Copying ${cfg} from ${ATL_JRIA_SHARED_HOME} into ${ATL_JIRA_HOME}"
    ensure_readable "${ATL_JIRA_SHARED_HOME}/${cfg}"
    if [ ! -f "${ATL_JIRA_SHARED_HOME}/${cfg}" ]; then
      error "Unable to find ${cfg} in ${ATL_JIRA_SHARED_HOME}, abort"
    else
      cp "${ATL_JIRA_SHARED_HOME}/${cfg}" "${ATL_JIRA_HOME}/${cfg}"
    fi
  done

  local tomcat_configs=(server.xml)
  for cfg in ${tomcat_configs}; do
    cp "${ATL_JIRA_SHARED_HOME}/${cfg}" "${ATL_JIRA_INSTALL_DIR}/conf/${cfg}"
  done
  atl_log configure_jira "Done configuring Tomcat!"

  atl_log configure_jira "Configuring cluster..."
  configure_cluster
  atl_log configure_jira "Done configuring cluster!"

  atl_log configure_jira "Configuring database driver..."
  install_jdbc_drivers
  atl_log configure_jira "Done configuring database driver!"

  atl_log configure_jira "Configuring app insights..."
  install_appinsights
  atl_log configure_jira "Done app insights!"

  configure_jira_ram

  chown -R jira:jira "/datadisks/disk1"
  chown -R jira:jira "${ATL_JIRA_HOME}"
  chown -R jira:jira "${ATL_JIRA_INSTALL_DIR}"
}

function remount_share {
  atl_log remount_share "Remounting shared home [${ATL_JIRA_SHARED_HOME}] so it's owned by JIRA"
  local uid=$(id -u jira)
  local gid=$(id -g jira)
  umount "${ATL_JIRA_SHARED_HOME}"
  atl_log remount_share "Temporary share has been unmounted!"
  atl_log remount_share "Permanently mounting [${ATL_JIRA_SHARED_HOME}] with [uid=${uid}, gid=${gid}] as owner"
  mount_share 1 $uid $gid
}

function prepare_datadisks {
  atl_log prepare_datadisks "Preparing data disks, striping, adding to fstab"
  ./vm-disk-utils-0.1.sh -b "/datadisks" -o "noatime,nodiratime,nodev,noexec,nosuid,nofail,barrier=0" -s
  atl_log prepare_datadisks "Creating symlink from [${ATL_JIRA_HOME}] to striped disk at [/datadisks/disk1]"
  mkdir -p $(dirname "${ATL_JIRA_HOME}")
  ln -d -s "/datadisks/disk1" "${ATL_JIRA_HOME}"
  atl_log prepare_datadisks "Done preparing and configuring data disks"
}

function set_shared_home_permissions {
  atl_log set_shared_home_permissions "Setting permissions for SSH user ${SERVER_SSH_USER} to access logs etc on shared home ${ATL_JIRA_HOME}"
  usermod -a -G jira ${SERVER_SSH_USER}
  chmod -R 774 ${ATL_JIRA_HOME}
  chmod -R 774 ${ATL_JIRA_INSTALL_DIR}
}

function install_oms_linux_agent {
  atl_log install_oms_linx_agent "Have OMS Workspace Key? |${OMS_WORKSPACE_ID}|"
  if [[ -n ${OMS_WORKSPACE_ID} ]]; then
    atl_log install_oms_linx_agent  "Installing OMS Linux Agent with workspace id: ${OMS_WORKSPACE_ID} and primary key: ${OMS_PRIMARY_KEY}"
    wget https://raw.githubusercontent.com/Microsoft/OMS-Agent-for-Linux/master/installer/scripts/onboard_agent.sh && sh onboard_agent.sh -w "${OMS_WORKSPACE_ID}" -s "${OMS_PRIMARY_KEY}" -d opinsights.azure.com
    atl_log install_oms_linx_agent  "Finished installing OMS Linux Agent!"
  fi
}

function disable_rhel_firewall {
  if [[ -n ${IS_REDHAT} ]]
  then
    atl_log disable_rhel_firewall  "Disabling RHEL Firewall - using Azure Cluster NSG to maintain access rules"
    systemctl stop firewalld.service
    systemctl disable firewalld.service
  fi
}

function preloadDatabase {
  atl_log preloadDatabase  "Preloading new database"
  prepare_password_generator
  install_password_generator
  prepare_server_id_generator
  prepare_database
  atl_log preloadDatabase "ready to hydrate db dump"
  apply_database_dump
}

function prepare_install {
  env | sort
  tune_tcp_keepalive_for_azure
  prepare_share
  download_installer
  preserve_installer
  hydrate_shared_config
  install_jdbc_drivers "`pwd`"
  if [ $DB_CREATE = 'true' ]
  then
     preloadDatabase
  fi
  copy_artefacts
}

function install_jira {
  env | sort
  tune_tcp_keepalive_for_azure
  atl_log install_jira "Ready to install JIRA"
  mount_share
  prepare_datadisks
  prepare_varfile
  prepare_installer
  prepare_fontconfig
  perform_install
  configure_jira
  remount_share
  install_oms_linux_agent
  systemctl enable jira
  atl_log install_jira "Done installing JIRA! Starting..."
  disable_rhel_firewall
  systemctl start jira
  install_appinsights_collectd
  set_shared_home_permissions
  copy_artefacts
}

# Spit out args
for (( i=1; i<="$#"; i++ ))
do
  atl_log main "Arg $i: ${!i}"
done

IS_REDHAT=$(cat /etc/os-release | egrep '^ID' | grep rhel)
install_pacapt
install_redhat_epel_if_needed
install_core_dependencies
prepare_env $1 $3 $5
source setenv.sh

if [ "$2" == "prepare" ]; then
  export SERVER_AZURE_DOMAIN="${3}"
  export DB_SERVER_NAME="${4}"
  export APPINSIGHTS_INSTRUMENTATION_KEY="${6}"
  prepare_install
fi

if [ "$2" == "install" ]; then
  export APPINSIGHTS_INSTRUMENTATION_KEY="${3}"
  install_jira
fi

if [ "$2" == "uninstall" ]; then
  if [ "$3" == "--yes-i-want-to-lose-everything" ]; then
    atl_log main "Uninstalling fully..."
    rm -rf "${ATL_JIRA_INSTALL_DIR}"
    rm -rf "${ATL_JIRA_HOME}"
    rm /etc/init.d/jira
    userdel jira
  fi
fi