#!/bin/bash
# LICENSE UPL 1.0
#
# Copyright (c) 1982-2018 Oracle and/or its affiliates. All rights reserved.
# 
# Since: November, 2016
# Author: gerald.venzl@oracle.com
# Description: Creates an Oracle Database based on following parameters:
#              $ORACLE_SID: The Oracle SID and CDB name
#              $ORACLE_PDB: The PDB name
#              $ORACLE_PWD: The Oracle password
# 
# DO NOT ALTER OR REMOVE COPYRIGHT NOTICES OR THIS HEADER.
# 

set -e

# Check whether ORACLE_SID is passed on
export ORACLE_SID=${1:-ORCLCDB}

# Check whether ORACLE_PDB is passed on
export ORACLE_PDB=${2:-ORCLPDB1}

# Checking if only one of INIT_SGA_SIZE & INIT_PGA_SIZE is provided by the user
if [[ "${INIT_SGA_SIZE}" != "" && "${INIT_PGA_SIZE}" == "" ]] || [[ "${INIT_SGA_SIZE}" == "" && "${INIT_PGA_SIZE}" != "" ]]; then
   echo "ERROR: Provide both the values, INIT_SGA_SIZE and INIT_PGA_SIZE or neither of them. Exiting.";
   exit 1;
fi;

# Use oracle as ORACLE PWD 
export ORACLE_PWD="oracle"
echo "ORACLE PASSWORD FOR SYS, SYSTEM AND PDBADMIN: $ORACLE_PWD";

# Replace place holders in response file
cp $ORACLE_BASE/$CONFIG_RSP $ORACLE_BASE/dbca.rsp
sed -i -e "s|###ORACLE_SID###|$ORACLE_SID|g" $ORACLE_BASE/dbca.rsp
sed -i -e "s|###ORACLE_PDB###|$ORACLE_PDB|g" $ORACLE_BASE/dbca.rsp
sed -i -e "s|###ORACLE_PWD###|$ORACLE_PWD|g" $ORACLE_BASE/dbca.rsp
sed -i -e "s|###ORACLE_CHARACTERSET###|$ORACLE_CHARACTERSET|g" $ORACLE_BASE/dbca.rsp

# If both INIT_SGA_SIZE & INIT_PGA_SIZE aren't provided by user
if [[ "${INIT_SGA_SIZE}" == "" && "${INIT_PGA_SIZE}" == "" ]]; then
    # If there is greater than 8 CPUs default back to dbca memory calculations
    # dbca will automatically pick 40% of available memory for Oracle DB
    # The minimum of 2G is for small environments to guarantee that Oracle has enough memory to function
    # However, bigger environment can and should use more of the available memory
    # This is due to Github Issue #307
    if [ `nproc` -gt 8 ]; then
        sed -i -e "s|totalMemory=2048||g" $ORACLE_BASE/dbca.rsp
    fi;
else
    sed -i -e "s|totalMemory=2048||g" $ORACLE_BASE/dbca.rsp
    sed -i -e "s|initParams=.*|&,sga_target=${INIT_SGA_SIZE}M,pga_aggregate_target=${INIT_PGA_SIZE}M|g" $ORACLE_BASE/dbca.rsp
fi;

# Create network related config files (sqlnet.ora, tnsnames.ora, listener.ora)
mkdir -p $ORACLE_HOME/network/admin
echo "NAME.DIRECTORY_PATH= (TNSNAMES, EZCONNECT, HOSTNAME)" > $ORACLE_HOME/network/admin/sqlnet.ora

# Listener.ora
echo "LISTENER = 
(DESCRIPTION_LIST = 
  (DESCRIPTION = 
    (ADDRESS = (PROTOCOL = IPC)(KEY = EXTPROC1)) 
    (ADDRESS = (PROTOCOL = TCP)(HOST = 0.0.0.0)(PORT = 1521)) 
  ) 
) 

DEDICATED_THROUGH_BROKER_LISTENER=ON
DIAG_ADR_ENABLED = off
" > $ORACLE_HOME/network/admin/listener.ora

# Start LISTENER and run DBCA
lsnrctl start &&
dbca -silent -createDatabase -responseFile $ORACLE_BASE/dbca.rsp ||
 cat /opt/oracle/cfgtoollogs/dbca/$ORACLE_SID/$ORACLE_SID.log ||
 cat /opt/oracle/cfgtoollogs/dbca/$ORACLE_SID.log

echo "$ORACLE_SID=localhost:1521/$ORACLE_SID" > $ORACLE_HOME/network/admin/tnsnames.ora
echo "$ORACLE_PDB= 
  (DESCRIPTION = 
    (ADDRESS = (PROTOCOL = TCP)(HOST = 0.0.0.0)(PORT = 1521))
    (CONNECT_DATA =
      (SERVER = DEDICATED)
      (SERVICE_NAME = $ORACLE_PDB)
    )
  )" >> $ORACLE_HOME/network/admin/tnsnames.ora

# Remove second control file, fix local_listener, make PDB auto open, enable EM global port
# Create externally mapped oracle user for health check
# Bunch of other stuff for EntwicklerDB an shit
# 
sqlplus / as sysdba << EOF
   ALTER SYSTEM SET control_files='$ORACLE_BASE/oradata/$ORACLE_SID/control01.ctl' scope=spfile;
   ALTER SYSTEM SET local_listener='';
   ALTER PLUGGABLE DATABASE $ORACLE_PDB SAVE STATE;
   EXEC DBMS_XDB_CONFIG.SETGLOBALPORTENABLED (TRUE);

   ALTER SESSION SET "_oracle_script" = true;
   CREATE USER OPS\$oracle IDENTIFIED EXTERNALLY;
   GRANT CREATE SESSION TO OPS\$oracle;
   GRANT SELECT ON sys.v_\$pdbs TO OPS\$oracle;
   ALTER USER OPS\$oracle SET container_data=all for sys.v_\$pdbs container = current;

   ALTER SESSION SET CONTAINER=$ORACLE_PDB;
   CREATE DIRECTORY SHARE_DIRECTORY AS '/share';
   CREATE TEMPORARY TABLESPACE CRONET_TEMP TEMPFILE 'cronet_temp.dbf' SIZE 5M AUTOEXTEND ON;
   ALTER USER SYSTEM ACCOUNT UNLOCK;
   @/opt/oracle/product/12.1.0.2/dbhome_1/demo/schema/db-sample-schemas-12.1.0.2/human_resources/hr_main.sql cronet system temp cronet /oracle/hr/log localhost:1521/impl
   exit;
EOF

java -jar /opt/SysAdmin/bin/cwSysadmin.jar -dpi XMLFILE=/opt/SysAdmin/config/saData_localhost_test_CW_cronet_docker.xml  impfile=CRONET_TRUNK.DMP impdir=SHARE_DIRECTORY FROMUSER=CRONET_TRUNK TOUSER=CRONET  CRONETGRANTS=false passwordtransfer=false createstatistics=false userdelete=true

java -jar /opt/SysAdmin/bin/cwSysadmin.jar -dpi XMLFILE=/opt/SysAdmin/config/saData_localhost_test_CW_cronet_docker.xml  impfile=UTPLSQL.DMP      impdir=SHARE_DIRECTORY FROMUSER=UTPLSQL TOUSER=UTPLSQL CRONETGRANTS=false passwordtransfer=false createstatistics=false userdelete=true

sqlplus / as sysdba << EOF
   ALTER SESSION SET CONTAINER=$ORACLE_PDB;
   ALTER USER CRONET identified by cronet;
   exit;
EOF

# Remove temporary response file
rm $ORACLE_BASE/dbca.rsp
