#!/bin/sh
PATH=/etc:/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin

PGPASSWORD=12345678
export PGPASSWORD
pathB=/backup-data/itsm-t-dba01/dump/
dbUser=backup_user
database=creatio_pp

pg_dump -U $dbUser $database -h itsm-t-dba01 -p 5432 > /backup-data/itsm-t-dba01/dump/creatio_pp.bac 2>/backup-data/itsm-t-dba01/pg_dump_error_mes.log

unset PGPASSWORD

echo "$?" > /backup-data/itsm-t-dba01/pg_dump_resut_code.txt