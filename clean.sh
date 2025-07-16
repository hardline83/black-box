#!/bin/sh

mv /backup-data/itsm-t-dba01/dump/creatio_pp* /backup-data/itsm-t-dba01/dump_archive/creatio_pp-$(date +%Y-%m-%d).bac

find /backup-data/itsm-t-dba01/dump_archive -name "*.bac" -type f -mtime +3 -delete