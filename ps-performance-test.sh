#!/bin/bash
# set -x

# **********************************************************************************************
# PS performance benchmark scripts
# Sysbench suite will run performance tests
# **********************************************************************************************

# generic variables
export RPORT=$(( RANDOM%21 + 10 ))
export RBASE="$(( RPORT*1000 ))"
export WORKSPACE=${WORKSPACE:-${PWD}}
export PS_START_TIMEOUT=100
export MYSQL_NAME=PS
# sysbench variables
export MYSQL_DATABASE=test
export SUSER=root
export RAND_SEED=${RAND_SEED:-1111}
SYSBENCH_DIR=${SYSBENCH_DIR:-/usr/local/share}

#MYEXTRA=${MYEXTRA:=--disable-log-bin}
#TASKSET_MYSQLD=${TASKSET_MYSQLD:=taskset -c 0}
#TASKSET_SYSBENCH=${TASKSET_SYSBENCH:=taskset -c 1}

command -v cpupower >/dev/null 2>&1 || { echo >&2 "cpupower is not installed. Aborting."; exit 1; }

function usage(){
  echo $1
  echo "Usage: $0 <BENCH_NAME> <BUILD_DIR> <MYSQL_CONFIG_FILE>"
  echo "where:"
  echo "<BENCH_NAME> - name of benchmark (a directory with this name will be created in \$WORKSPACE)"
  echo "<BUILD_DIR> - relative path to MySQL or Percona Server binaries (inside \$WORKSPACE)"
  echo "<MYSQL_CONFIG_FILE> - full path to Percona Server's configuration file"
  echo "Usage example:"
  echo "$0 100 Percona-Server-8.0.34-26-Linux.x86_64.glibc2.35 cnf/percona-innodb.cnf"
  echo "This would lead to $WORKSPACE/100 being created, in which testing takes place and"
  echo "$WORKSPACE/Percona-Server-8.0.34-26-Linux.x86_64.glibc2.35 would be used to test."
  exit 1
}

export BENCH_NUMBER=$1
export BENCH_DIR=$WORKSPACE/$1
export DB_DIR=$BENCH_DIR/$2
export DATA_DIR=$BENCH_DIR/datadir
export LOGS=$BENCH_DIR/logs

# check parameters
echo "Using WORKSPACE=$WORKSPACE"
if [ $# -lt 3 ]; then usage "ERROR: Too little parameters passed"; fi
if [[ ! -d $WORKSPACE/$2 ]]; then usage "ERROR: Couldn't find binaries in $WORKSPACE/$2"; fi

mkdir -p $LOGS
cd $WORKSPACE
export CONFIG_FILES="$3"
echo "Copying server binaries from $WORKSPACE/$2 to $BENCH_DIR/$2"
cp -r $WORKSPACE/$2 $BENCH_DIR || usage "ERROR: Failed to copy binaries from $WORKSPACE/$2 to $BENCH_DIR/$2"

export MYSQL_VERSION=`$DB_DIR/bin/mysqld --version | awk '{ print $3}'`

archives() {
  tar czf ${WORKSPACE}/results-${BENCH_NUMBER}.tar.gz ${BENCH_NUMBER}/logs --transform "s+^${BENCH_NUMBER}/logs++"
}

trap archives EXIT KILL

if [ ! -d ${WORKSPACE}/backups ]; then
  mkdir -p ${WORKSPACE}/backups
  SCP_TARGET=${WORKSPACE}/backups
else
  SCP_TARGET=${WORKSPACE}/backups
fi

if [ -z $WORKSPACE ]; then
  echo "Assuming this is a local (i.e. non-Jenkins initiated) run."
  export WORKSPACE=$WORKSPACE/backups
fi

function start_ps_node(){
  ps -ef | grep 'ps_socket.sock' | grep ${BENCH_NUMBER} | grep -v grep | awk '{print $2}' | xargs kill -9 >/dev/null 2>&1 || true
  BIN=`find ${DB_DIR} -maxdepth 2 -name mysqld -type f -o -name mysqld-debug -type f | head -1`;if [ -z $BIN ]; then echo "Assert! mysqld binary '$BIN' could not be read";exit 1;fi
  EXTRA_PARAMS=$MYEXTRA
  EXTRA_PARAMS+=" --innodb-buffer-pool-size=$INNODB_CACHE"
  RBASE="$(( RBASE + 100 ))"
  if [ "$1" == "startup" ];then
    node="${WS_DATADIR}/datadir_${NUM_TABLES}x${DATASIZE}"
    if [ ! -d $node ]; then
      ${TASKSET_MYSQLD} ${DB_DIR}/bin/mysqld --no-defaults --initialize-insecure --basedir=${DB_DIR} --datadir=$node  > $LOGS/startup.err 2>&1
    fi
    EXTRA_PARAMS+=" --disable-log-bin"
  else
    node="${DATA_DIR}"
  fi

  MYSQLD_OPTIONS="--defaults-file=${CONFIG_FILE} --datadir=$node --basedir=${DB_DIR} $EXTRA_PARAMS --log-error=${LOGS_CONFIG}/master.err --socket=$MYSQL_SOCKET --port=$RBASE"
  echo "Starting Percona Server with options $MYSQLD_OPTIONS"
  ${TASKSET_MYSQLD} ${DB_DIR}/bin/mysqld $MYSQLD_OPTIONS > ${LOGS_CONFIG}/master.err 2>&1 &

  for X in $(seq 0 ${PS_START_TIMEOUT}); do
    sleep 1
    if ${DB_DIR}/bin/mysqladmin -uroot -S$MYSQL_SOCKET ping > /dev/null 2>&1; then
      echo "Started Percona Server. Socket=$MYSQL_SOCKET Port=$RBASE"
      break
    fi
  done
  ${DB_DIR}/bin/mysqladmin -uroot -S$MYSQL_SOCKET ping > /dev/null 2>&1 || { echo “Couldn\'t connect $MYSQL_SOCKET” && exit 0; }

  if [ "$1" == "startup" ];then
    echo "Creating data directory in $node"
    ${DB_DIR}/bin/mysql -uroot -S$MYSQL_SOCKET -e "CREATE DATABASE IF NOT EXISTS $MYSQL_DATABASE" 2>&1
    time ${TASKSET_SYSBENCH} sysbench $SYSBENCH_DIR/sysbench/oltp_insert.lua --threads=$NUM_TABLES $SYSBENCH_OPTIONS --mysql-socket=$MYSQL_SOCKET prepare 2>&1 | tee $LOGS/sysbench_prepare.log
    echo -e "Data directory in $node created\nShutting mysqld down"
    time ${DB_DIR}/bin/mysqladmin -uroot --socket=$MYSQL_SOCKET shutdown > /dev/null 2>&1
  fi
}

function check_memory(){
  CHECK_PID=`ps -ef | grep ps_socket | grep -v grep | awk '{ print $2}'`
  WAIT_TIME_SECONDS=10
  RUN_TIME_SECONDS=$(($RUN_TIME_SECONDS + $WARMUP_TIME_SECONDS))
  while [ ${RUN_TIME_SECONDS} -gt 0 ]; do
    DATE=`date +"%Y%m%d%H%M%S"`
    CURRENT_INFO=`ps -o rss,vsz,pcpu ${CHECK_PID} | tail -n 1`
    echo "${DATE} ${CURRENT_INFO}" >> ${LOG_NAME_MEMORY}
    RUN_TIME_SECONDS=$(($RUN_TIME_SECONDS - $WAIT_TIME_SECONDS))
    sleep ${WAIT_TIME_SECONDS}
  done
}

function restore_address_randomization(){
    CURRENT_ASLR=`cat /proc/sys/kernel/randomize_va_space`
    sudo sh -c "echo $PREVIOUS_ASLR > /proc/sys/kernel/randomize_va_space"
    echo "Resoring /proc/sys/kernel/randomize_va_space from $CURRENT_ASLR to `cat /proc/sys/kernel/randomize_va_space`"
}

function disable_address_randomization(){
    PREVIOUS_ASLR=`cat /proc/sys/kernel/randomize_va_space`
    sudo sh -c "echo 0 > /proc/sys/kernel/randomize_va_space"
    echo "Setting /proc/sys/kernel/randomize_va_space from $PREVIOUS_ASLR to `cat /proc/sys/kernel/randomize_va_space`"
}

function restore_turbo_boost(){
  echo "Restore turbo boost with $SCALING_DRIVER scaling driver"

  if [[ ${SCALING_DRIVER} == "intel_pstate" || ${SCALING_DRIVER} == "intel_cpufreq" ]]; then
    CURRENT_TURBO=`cat /sys/devices/system/cpu/intel_pstate/no_turbo`
    sudo sh -c "echo $PREVIOUS_TURBO > /sys/devices/system/cpu/intel_pstate/no_turbo"
    echo "Setting /sys/devices/system/cpu/intel_pstate/no_turbo from $CURRENT_TURBO to $PREVIOUS_TURBO"
  else
    CURRENT_TURBO=`cat /sys/devices/system/cpu/cpufreq/boost`
    sudo sh -c "echo $PREVIOUS_TURBO > /sys/devices/system/cpu/cpufreq/boost"
    echo "Setting /sys/devices/system/cpu/cpufreq/boost from $CURRENT_TURBO to $PREVIOUS_TURBO"
  fi
}

function disable_turbo_boost(){
  SCALING_DRIVER=`cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver`
  echo "Using $SCALING_DRIVER scaling driver"

  if [[ ${SCALING_DRIVER} == "intel_pstate" || ${SCALING_DRIVER} == "intel_cpufreq" ]]; then
    PREVIOUS_TURBO=`cat /sys/devices/system/cpu/intel_pstate/no_turbo`
    sudo sh -c "echo 1 > /sys/devices/system/cpu/intel_pstate/no_turbo"
    echo "Setting /sys/devices/system/cpu/intel_pstate/no_turbo from $PREVIOUS_TURBO to `cat /sys/devices/system/cpu/intel_pstate/no_turbo`"
  else
    PREVIOUS_TURBO=`cat /sys/devices/system/cpu/cpufreq/boost`
    sudo sh -c "echo 0 > /sys/devices/system/cpu/cpufreq/boost"
    echo "Setting /sys/devices/system/cpu/cpufreq/boost from $PREVIOUS_TURBO to `cat /sys/devices/system/cpu/cpufreq/boost`"
  fi
}

function restore_scaling_governor(){
  CURRENT_GOVERNOR=`cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor`
  sudo cpupower frequency-set -g $PREVIOUS_GOVERNOR
  echo "Changed scaling governor from $CURRENT_GOVERNOR to `cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor`"
  sudo cpupower frequency-info
}

function change_scaling_governor(){
  PREVIOUS_GOVERNOR=`cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor`
  sudo cpupower frequency-set -g $1
  echo "Changed scaling governor from $PREVIOUS_GOVERNOR to `cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor`"
  sudo cpupower frequency-info
}

function enable_idle_states(){
  sudo cpupower idle-set --enable-all
  sudo cpupower idle-info
}

function disable_idle_states(){
  sudo cpupower idle-set --disable-by-latency 0
  sudo cpupower idle-info
}

function drop_caches(){
  echo "Dropping caches"
  sync
  sudo sh -c 'sysctl -q -w vm.drop_caches=3'
  sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches'
  ulimit -n 1000000
}

function start_ps(){
  MYSQL_SOCKET=${LOGS}/ps_socket.sock
  timeout --signal=9 20s ${DB_DIR}/bin/mysqladmin -uroot --socket=$MYSQL_SOCKET shutdown > /dev/null 2>&1
  ps -ef | grep 'ps_socket' | grep ${BENCH_NUMBER} | grep -v grep | awk '{print $2}' | xargs kill -9 >/dev/null 2>&1 || true
  BIN=`find ${DB_DIR} -maxdepth 2 -name mysqld -type f -o -name mysqld-debug -type f | head -1`;if [ -z $BIN ]; then echo "Assert! mysqld binary '$BIN' could not be read";exit 1;fi
  NUM_ROWS=$(numfmt --from=si $DATASIZE)
  SYSBENCH_OPTIONS="--table-size=$NUM_ROWS --tables=$NUM_TABLES --mysql-db=$MYSQL_DATABASE --mysql-user=$SUSER --report-interval=10 --db-driver=mysql --db-ps-mode=disable --rand-seed=$RAND_SEED"
  WS_DATADIR="${WORKSPACE}/80_sysbench_data_template"

  drop_caches
  if [ ! -d ${WS_DATADIR}/datadir_${NUM_TABLES}x${DATASIZE} ]; then
    mkdir ${WS_DATADIR} > /dev/null 2>&1
    start_ps_node startup
  fi
  echo "Copying data directory from ${WS_DATADIR}/datadir_${NUM_TABLES}x${DATASIZE} to ${DATA_DIR}"
  rm -rf ${DATA_DIR}
  cp -r ${WS_DATADIR}/datadir_${NUM_TABLES}x${DATASIZE} ${DATA_DIR}
  start_ps_node
}

function run_sysbench(){
  MEM_PID=()
  if [[ ${WARMUP_TIME_AT_START} > 0 ]]; then
    # *** REMEMBER *** warmmup is READ ONLY!
    # warmup the cache, 64 threads for $WARMUP_TIME_AT_START seconds,
    num_threads=64
    echo "Warming up for $WARMUP_TIME_AT_START seconds"
    ${TASKSET_SYSBENCH} sysbench $SYSBENCH_DIR/sysbench/oltp_read_only.lua --threads=$num_threads --time=$WARMUP_TIME_AT_START $SYSBENCH_OPTIONS --rand-type=$RAND_TYPE --mysql-socket=$MYSQL_SOCKET --percentile=99 run > ${LOGS_CONFIG}/sysbench_warmup.log 2>&1
    sleep $[WARMUP_TIME_AT_START/10]
  fi
  echo "Storing Sysbench results in ${WORKSPACE}"
  for lua_script in ${LUA_SCRIPTS}; do
    BENCH_ID=${lua_script%.*}-${NUM_TABLES}x${DATASIZE}-${INNODB_CACHE}

    for num_threads in ${THREADS_LIST}; do
      echo "Testing $lua_script with $num_threads threads"
      LOG_NAME_RESULTS=${LOGS_CONFIG}/results-QPS-${BENCH_ID}.txt
      LOG_NAME=${LOGS_CONFIG}/${MYSQL_NAME}-${MYSQL_VERSION}-${BENCH_ID}-$num_threads.txt
      LOG_NAME_MEMORY=${LOG_NAME}.memory
      LOG_NAME_IOSTAT=${LOG_NAME}.iostat
      LOG_NAME_DSTAT=${LOG_NAME}.dstat
      LOG_NAME_DSTAT_CSV=${LOG_NAME}.dstat.csv
      LOG_NAME_INXI=${LOG_NAME}.inxi

      if [ ${BENCHMARK_LOGGING} == "Y" ]; then
          # verbose logging
          echo "*** verbose benchmark logging enabled ***"
          check_memory &
          MEM_PID+=("$!")
          iostat -dxm $IOSTAT_INTERVAL $IOSTAT_ROUNDS  > $LOG_NAME_IOSTAT &
          dstat -t -v --nocolor --output $LOG_NAME_DSTAT_CSV $DSTAT_INTERVAL $DSTAT_ROUNDS > $LOG_NAME_DSTAT &
          rm -f $LOG_NAME_INXI
          (x=1; while [ $x -le $DSTAT_ROUNDS ]; do inxi -C -c 0 >> $LOG_NAME_INXI; sleep $DSTAT_INTERVAL; x=$(( $x + 1 )); done) &
      fi
      ${TASKSET_SYSBENCH} sysbench $SYSBENCH_DIR/sysbench/$lua_script --threads=$num_threads --time=$RUN_TIME_SECONDS --warmup-time=$WARMUP_TIME_SECONDS $SYSBENCH_OPTIONS --rand-type=$RAND_TYPE --mysql-socket=$MYSQL_SOCKET --percentile=99 run | tee $LOG_NAME
      sleep 6
      result_set+=(`grep  "queries:" $LOG_NAME | cut -d'(' -f2 | awk '{print $1 ","}'`)
    done

    pkill -f dstat
    pkill -f iostat
    kill -9 ${MEM_PID[@]}
    for i in {0..7}; do if [ -z ${result_set[i]} ]; then  result_set[i]='0,' ; fi; done
    echo "[ '${BENCH_NUMBER}_${CONFIG_BASE}_${BENCH_ID}', ${result_set[*]} ]," >> ${LOG_NAME_RESULTS}
    cat ${LOG_NAME_RESULTS} >> ${LOGS}/sysbench_${BENCH_ID}_${BENCH_NUMBER}_perf_result_set.txt
    unset result_set
  done

  timeout --signal=9 20s ${DB_DIR}/bin/mysqladmin -uroot --socket=$MYSQL_SOCKET shutdown > /dev/null 2>&1
  ps -ef | grep 'ps_socket' | grep ${BENCH_NUMBER} | grep -v grep | awk '{print $2}' | xargs kill -9 >/dev/null 2>&1 || true
}

function archive_logs(){
  BENCH_ID=${NUM_TABLES}x${DATASIZE}-${INNODB_CACHE}
  DATE=`date +"%Y%m%d%H%M%S"`
  tarFileName="sysbench_${BENCH_ID}_perf_result_set_${BENCH_NUMBER}_${DATE}.tar.gz"
  tar czvf ${tarFileName} ${BENCH_NUMBER}/logs --transform "s+^${BENCH_NUMBER}/logs++"

  mkdir -p ${SCP_TARGET}/${BENCH_NUMBER}/${BENCH_SUITE}/${BENCH_ID}
  BACKUP_FILES="${SCP_TARGET}/${BENCH_NUMBER}/${BENCH_SUITE}/${BENCH_ID}"
  cp ${tarFileName} ${BACKUP_FILES}
  rm -rf ${DATA_DIR}
}

# **********************************************************************************************
# sysbench
# **********************************************************************************************
export THREADS_LIST=${THREADS_LIST:="0001 0004 0016 0064 0128 0256 0512 1024"}
export LUA_SCRIPTS=${LUA_SCRIPTS:="oltp_read_write.lua"}
export BENCHMARK_LOGGING=Y
WARMUP_TIME_AT_START=${WARMUP_TIME_AT_START:-600}
export WARMUP_TIME_SECONDS=${WARMUP_TIME_SECONDS:=30}
export RUN_TIME_SECONDS=${RUN_TIME_SECONDS:-600}
export REPORT_INTERVAL=10
export IOSTAT_INTERVAL=10
export IOSTAT_ROUNDS=$[(RUN_TIME_SECONDS+WARMUP_TIME_SECONDS)/IOSTAT_INTERVAL+1]
export DSTAT_INTERVAL=10
export DSTAT_ROUNDS=$[(RUN_TIME_SECONDS+WARMUP_TIME_SECONDS)/DSTAT_INTERVAL+1]
export BENCH_SUITE=sysbench

export INNODB_CACHE=${INNODB_CACHE:-32G}
export NUM_TABLES=${NUM_TABLES:-16}
export DATASIZE=${DATASIZE:-10M}
export RAND_TYPE=${RAND_TYPE:-uniform}

rm -rf ${LOGS}
mkdir -p ${LOGS}
LOGS_CPU=$LOGS/cpu-states.txt

disable_turbo_boost > ${LOGS_CPU}
change_scaling_governor powersave >> ${LOGS_CPU}
disable_idle_states >> ${LOGS_CPU}
disable_address_randomization >> ${LOGS_CPU}

for file in $CONFIG_FILES; do
  if [ ! -f $file ]; then usage "ERROR: Config file $file not found."; fi
  CONFIG_BASE=$(basename ${file%.*})
  LOGS_CONFIG=${LOGS}/${BENCH_NUMBER}-${CONFIG_BASE}
  mkdir -p ${LOGS_CONFIG}
  CONFIG_FILE=${LOGS_CONFIG}/$(basename $file)
  cp $file $CONFIG_FILE
  echo "Using $CONFIG_FILE as mysqld config file"

  start_ps
  run_sysbench
done

restore_turbo_boost >> ${LOGS_CPU}
restore_scaling_governor >> ${LOGS_CPU}
enable_idle_states >> ${LOGS_CPU}
restore_address_randomization >> ${LOGS_CPU}

VERSION_INFO=`$DB_DIR/bin/mysqld --version | cut -d' ' -f2-`
UPTIME_HOUR=`uptime -p`
SYSTEM_LOAD=`uptime | sed 's|  | |g' | sed -e 's|.*user*.,|System|'`
MEM=`free -g | grep "Mem:" | awk '{print "Total:"$2"GB  Used:"$3"GB  Free:"$4"GB" }'`
if [ ! -f $LOGS/hw.info ];then
  if [ -f /etc/redhat-release ]; then
    RELEASE=`cat /etc/redhat-release`
  else
    RELEASE=`cat /etc/issue`
  fi
  KERNEL=`uname -r`
  echo "HW info | $RELEASE $KERNEL"  > $LOGS/hw.info
fi
echo "Build #$BENCH_NUMBER | `date +'%d-%m-%Y | %H:%M'` | $VERSION_INFO | $UPTIME_HOUR | $SYSTEM_LOAD | Memory: $MEM " >> $LOGS/build_info.log
cat ${LOGS}/sysbench_*_perf_result_set.txt > ${LOGS}/sysbench_${BENCH_NUMBER}_full_result_set.txt
cat ${LOGS}/sysbench_*_perf_result_set.txt

archive_logs
exit 0
