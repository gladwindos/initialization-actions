#!/usr/bin/env bash

set -euxo pipefail

source "/usr/local/share/google/dataproc/bdutil/bdutil_helpers.sh"

readonly ATLAS_HOME="/usr/lib/atlas"
readonly ATLAS_ETC_DIR="/etc/atlas/conf"
readonly ATLAS_CONFIG="${ATLAS_ETC_DIR}/atlas-application.properties"
readonly INIT_SCRIPT="/usr/lib/systemd/system/atlas.service"

readonly ATLAS_ADMIN_USERNAME="$(/usr/share/google/get_metadata_value attributes/ATLAS_ADMIN_USERNAME || echo '')"
readonly ATLAS_ADMIN_PASSWORD_SHA256="$(/usr/share/google/get_metadata_value attributes/ATLAS_ADMIN_PASSWORD_SHA256 || echo '')"
readonly MASTER=$(/usr/share/google/get_metadata_value attributes/dataproc-master)
readonly ROLE=$(/usr/share/google/get_metadata_value attributes/dataproc-role)
readonly ADDITIONAL_MASTER=$(/usr/share/google/get_metadata_value attributes/dataproc-master-additional)

function retry_command() {
  local retry_backoff=(1 1 2 3 5 8 13 21 34 55 89 144)
  local -a cmd=("$@")
  loginfo "About to run '${cmd[*]}' with retries..."

  local update_succeeded=0
  for ((i = 0; i < ${#retry_backoff[@]}; i++)); do
    if eval "${cmd[@]}"; then
      update_succeeded=1
      break
    else
      local sleep_time=${retry_backoff[$i]}
      loginfo "'${cmd[*]}' attempt $((i + 1)) failed! Sleeping ${sleep_time}." >&2
      sleep "${sleep_time}"
    fi
  done

  if ! ((update_succeeded)); then
    loginfo "Final attempt of '${cmd[*]}'..."
    # Let any final error propagate all the way out to any error traps.
    "${cmd[@]}"
  fi
}

function err() {
  echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')]: $*" >&2
  exit 1
}

function check_prerequisites() {
  # check for Zookeeper
  wait_for_port "Zookeeper" localhost 2181

  # check for HBase
  if [[ "${ROLE}" == 'Master' ]]; then
    # systemctl is-active hbase-master || err 'HBase Master is not active'
    wait_for_port "HBase Master" localhost 16010
    retry_command systemctl is-active hbase-master
  else
    retry_command systemctl is-active hbase-regionserver
  fi

  # Systemd and port checking are not deterministic for HBase Master
  retry_command "echo create \'$(hostname)\',\'$(hostname)\' | hbase shell -n"
  retry_command "echo disable \'$(hostname)\' | hbase shell -n"
  retry_command "echo drop \'$(hostname)\' | hbase shell -n"

  # check for Solr
  curl 'http://localhost:8983/solr' || err 'Solr not found'

  if [[ -n "${ADDITIONAL_MASTER}" ]]; then
    # check for Kafka on HA
    ls /usr/lib/kafka &>/dev/null || err 'Kafka not found'
  fi
}

function configure_solr() {
  if [[ $(hostname) == "${MASTER}" ]]; then
    # configure Solr only on the one actual Master node
    runuser -l solr -s /bin/bash -c "/usr/lib/solr/bin/solr create -c vertex_index -d ${ATLAS_ETC_DIR}/solr -shards 3"
    runuser -l solr -s /bin/bash -c "/usr/lib/solr/bin/solr create -c edge_index -d ${ATLAS_ETC_DIR}/solr -shards 3"
    runuser -l solr -s /bin/bash -c "/usr/lib/solr/bin/solr create -c fulltext_index -d ${ATLAS_ETC_DIR}/solr -shards 3"
  fi
}

function configure_atlas() {
  local zk_quorum
  zk_quorum=$(bdconfig get_property_value --configuration_file /etc/hbase/conf/hbase-site.xml \
    --name hbase.zookeeper.quorum 2>/dev/null)
  local zk_url_for_solr
  zk_url_for_solr="$(echo "${zk_quorum}" | sed 's/:2181/:2181\/solr/g')"

  local cluster_name
  cluster_name=$(/usr/share/google/get_metadata_value attributes/dataproc-cluster-name)

  # Symlink HBase conf dir
  mkdir "${ATLAS_HOME}/hbase"
  ln -s "/etc/hbase/conf" "${ATLAS_HOME}/hbase/conf"

  # Configure Atlas
  sed -i "s/atlas.graph.storage.hostname=.*/atlas.graph.storage.hostname=${zk_quorum}/" ${ATLAS_CONFIG}
  sed -i "s/atlas.graph.storage.hbase.table=.*/atlas.graph.storage.hbase.table=atlas/" ${ATLAS_CONFIG}

  sed -i "s/atlas.rest.address=.*/atlas.rest.address=http:\/\/$(hostname):21000/" ${ATLAS_CONFIG}
  sed -i "s/atlas.audit.hbase.zookeeper.quorum=.*/atlas.audit.hbase.zookeeper.quorum=${zk_quorum}/" ${ATLAS_CONFIG}

  if [[ -n "${ADDITIONAL_MASTER}" ]]; then
    # Configure HA
    sed -i "s/atlas.server.ha.enabled=.*/atlas.server.ha.enabled=true/" ${ATLAS_CONFIG}
    sed -i "s/atlas.server.ha.zookeeper.connect=.*/atlas.server.ha.zookeeper.connect=${zk_quorum}/" ${ATLAS_CONFIG}
    sed -i "s/atlas.graph.index.search.solr.wait-searcher=.*/#atlas.graph.index.search.solr.wait-searcher=.*/" ${ATLAS_CONFIG}
    sed -i "s|atlas.graph.index.search.solr.zookeeper-url=.*|atlas.graph.index.search.solr.zookeeper-url=${zk_url_for_solr}|" ${ATLAS_CONFIG}

    cat <<EOF >>${ATLAS_CONFIG}
atlas.server.ids=m0,m1,m2
atlas.server.address.m0=${cluster_name}-m-0:21000
atlas.server.address.m1=${cluster_name}-m-1:21000
atlas.server.address.m2=${cluster_name}-m-2:21000
atlas.server.ha.zookeeper.zkroot=/apache_atlas
atlas.client.ha.retries=4
atlas.client.ha.sleep.interval.ms=5000
EOF
  else

    # Disable Solr Cloud
    sed -i "s/atlas.graph.index.search.solr.mode=cloud/#atlas.graph.index.search.solr.mode=cloud/" ${ATLAS_CONFIG}
    sed -i "s/atlas.graph.index.search.solr.zookeeper-url=.*/#atlas.graph.index.search.solr.zookeeper-url=.*/" ${ATLAS_CONFIG}
    sed -i "s/atlas.graph.index.search.solr.zookeeper-connect-timeout=.*/#atlas.graph.index.search.solr.zookeeper-connect-timeout=.*/" ${ATLAS_CONFIG}
    sed -i "s/atlas.graph.index.search.solr.zookeeper-session-timeout=.*/#atlas.graph.index.search.solr.zookeeper-session-timeout=.*/" ${ATLAS_CONFIG}
    sed -i "s/atlas.graph.index.search.solr.wait-searcher=.*/#atlas.graph.index.search.solr.wait-searcher=.*/" ${ATLAS_CONFIG}

    # Enable Solr HTTP
    sed -i "s/#atlas.graph.index.search.solr.mode=http/atlas.graph.index.search.solr.mode=http/" ${ATLAS_CONFIG}
    sed -i "s/#atlas.graph.index.search.solr.http-urls=.*/atlas.graph.index.search.solr.http-urls=http:\/\/${MASTER}:8983\/solr/" ${ATLAS_CONFIG}

  fi

  # Override default admin username:password
  if [[ -n "${ATLAS_ADMIN_USERNAME}" && -n "${ATLAS_ADMIN_PASSWORD_SHA256}" ]]; then
    sed -i "s/admin=.*/${ATLAS_ADMIN_USERNAME}=ROLE_ADMIN::${ATLAS_ADMIN_PASSWORD_SHA256}/" \
      "${ATLAS_HOME}/conf/users-credentials.properties"
  fi

  # Configure to use local Kafka
  if ls /usr/lib/kafka &>/dev/null; then
    sed -i "s/atlas.notification.embedded=.*/atlas.notification.embedded=false/" ${ATLAS_CONFIG}
    sed -i "s/atlas.kafka.zookeeper.connect=.*/atlas.kafka.zookeeper.connect=${zk_quorum}/" ${ATLAS_CONFIG}
    sed -i "s/atlas.kafka.bootstrap.servers=.*/atlas.kafka.bootstrap.servers=$(hostname):9092/" ${ATLAS_CONFIG}
  fi

}

function start_atlas() {
  cat <<EOF >${INIT_SCRIPT}
[Unit]
Description=Apache Atlas

[Service]
Type=forking
ExecStart=${ATLAS_HOME}/bin/atlas_start.py
ExecStop=${ATLAS_HOME}/bin/atlas_stop.py
RemainAfterExit=yes
TimeoutSec=10m

[Install]
WantedBy=multi-user.target
EOF
  chmod a+rw ${INIT_SCRIPT}
  systemctl enable atlas
  nohup systemctl start atlas || err 'Unable to start atlas service'

  # Check if 'atlas' table gets created and disabled. Make sure that
  # it is enabled to avoid Atlas failures.
  for ((i = 0; i < 60; i++)); do
    cmd_check_table_exist="echo exists \'atlas\' | hbase shell -n | grep -q 'does exist'"
    if eval "${cmd_check_table_exist}"; then
      cmd_is_disabled="echo is_disabled \'atlas\' | hbase shell -n | grep -q 'true'"
      if eval "${cmd_is_disabled}"; then
        retry_command "echo enable \'atlas\' | hbase shell -n"
      else
        break
      fi
    fi
    sleep 20
  done
}

function wait_for_atlas_to_start() {
  # atlas start script exits prematurely, before atlas actually starts
  # thus wait up to 10 minutes until atlas is fully working
  wait_for_port "Atlas web server" localhost 21000
  local -r cmd='curl localhost:21000/api/atlas/admin/status'
  for ((i = 0; i < 60; i++)); do
    if eval "${cmd}"; then
      return 0
    fi
    sleep 20
  done
  return 1
}

function wait_for_atlas_becomes_active_or_passive() {
  cmd="sudo ${ATLAS_HOME}/bin/atlas_admin.py -u doesnt:matter -status 2>/dev/null" # public check, but some username:password has to be given
  for ((i = 0; i < 60; i++)); do
    if status=$(eval "${cmd}"); then
      if [[ ${status} == 'ACTIVE' || ${status} == 'PASSIVE' ]]; then
        return 0
      fi
    fi
    sleep 10
  done
  return 1
}

function enable_hive_hook() {
  bdconfig set_property \
    --name 'hive.exec.post.hooks' \
    --value 'org.apache.atlas.hive.hook.HiveHook' \
    --configuration_file '/etc/hive/conf/hive-site.xml' \
    --clobber

  echo "export HIVE_AUX_JARS_PATH=${ATLAS_HOME}/hook/hive" >>/etc/hive/conf/hive-env.sh
  ln -s ${ATLAS_CONFIG} /etc/hive/conf/
}

function enable_hbase_hook() {
  bdconfig set_property \
    --name 'hbase.coprocessor.master.classes' \
    --value 'org.apache.atlas.hbase.hook.HBaseAtlasCoprocessor' \
    --configuration_file '/etc/hbase/conf/hbase-site.xml' \
    --clobber

  ln -s ${ATLAS_HOME}/hook/hbase/* /usr/lib/hbase/lib/
  ln -s ${ATLAS_CONFIG} /etc/hbase/conf/

  sudo service hbase-master restart
}

function enable_sqoop_hook() {
  if [[ ! -f /usr/lib/sqoop ]]; then
    echo 'Sqoop not found, not configuring hook'
    return
  fi

  if [[ ! -f /usr/lib/sqoop/conf/sqoop-site.xml ]]; then
    cp /usr/lib/sqoop/conf/sqoop-site-template.xml /usr/lib/sqoop/conf/sqoop-site.xml
  fi

  bdconfig set_property \
    --name 'sqoop.job.data.publish.class' \
    --value 'org.apache.atlas.sqoop.hook.SqoopHook' \
    --configuration_file '/usr/lib/sqoop/conf/sqoop-site.xml' \
    --clobber

  ln -s ${ATLAS_HOME}/hook/sqoop/* /usr/lib/sqoop/lib
  ln -s ${ATLAS_CONFIG} /usr/lib/sqoop/conf

  sudo service hbase-master restart
}

function main() {
   if ! is_version_at_least "${DATAPROC_VERSION}" "1.5"; then
    err "Dataproc ${DATAPROC_VERSION} is not supported"
  fi

  if [[ "${ROLE}" == 'Master' ]]; then
    check_prerequisites
    retry_command "apt-get install -q -y atlas"
    configure_solr
    configure_atlas
    enable_hive_hook
    enable_hbase_hook
    enable_sqoop_hook
    start_atlas
    wait_for_atlas_to_start
    wait_for_atlas_becomes_active_or_passive
  fi
}

main
