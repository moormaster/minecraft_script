#!/bin/bash

# default settings
MINECRAFT_RUN_DIR=
MINECRAFT_RUN_MEM=1024m
MINECRAFT_RUN_WORLD=world
MINECRAFT_RUN_USER=

MINECRAFT_BACKUP_DIR=
MINECRAFT_BACKUP_MAXAGE_DAYS=7

MINECRAFT_MAP_DIR=

# mapping tools
MINECRAFT_MAP_FUNC=

MINECRAFT_MAP_C10TDIR=
MINECRAFT_MAP_MINECRAFTOVERVIEWERDIR=

MINECRAFT_UPDATE_URL="https://minecraft.net/download"
MINECRAFT_UPDATE_XPATH="string(descendant::a[@data-dist='server' and  @data-platform='linux']/@href)"
MINECRAFT_UPDATE_WGETOPTS="--no-check-certificate"
MINECRAFT_SCRIPT_FILE="$( readlink -f "$0" )"
MINECRAFT_SCRIPT_DIR="$( dirname "$MINECRAFT_SCRIPT_FILE" )"

if [ -e "$MINECRAFT_SCRIPT_DIR/minecraft_settings.sh" ]
then
	. "$MINECRAFT_SCRIPT_DIR/minecraft_settings.sh"
fi

# initialize
MINECRAFT_RUN_PID="$MINECRAFT_RUN_DIR/minecraft.pid"
MINECRAFT_RUN_FIFO="$MINECRAFT_RUN_DIR/minecraft.fifo"
MINECRAFT_RUN_LOG="$MINECRAFT_RUN_DIR/minecraft.log"

MINECRAFT_BACKUP_SOURCEDIR="$MINECRAFT_RUN_DIR/$MINECRAFT_RUN_WORLD"

MINECRAFT_MAP_WORLDDIR="$MINECRAFT_RUN_DIR/$MINECRAFT_RUN_WORLD"

INVOCATION="$0"
INVOCATIONARGS=( "$@" )

usage()
{
	echo "usage: $0 <start|stop|update|backup|autoclean-backups|create-map|command>"
	exit 1
}

verify-settings()
{
	RES=0

	if ! [ -d "$MINECRAFT_RUN_DIR" ]
	then
		echo MINECRAFT_RUN_DIR does not exist: $MINECRAFT_RUN_DIR
		RES=1
	fi

	if ! [ -d "$MINECRAFT_RUN_DIR/$MINECRAFT_RUN_WORLD" ]
	then
		echo MINECRAFT_RUN_WORLD does not exist: $MINECRAFT_RUN_DIR/$MINECRAFT_RUN_WORLD
		RES=1
	fi

	if ! [ -d "$MINECRAFT_BACKUP_SOURCEDIR" ]
	then
		echo MINECRAFT_BACKUP_SOURCEDIR does not exist: $MINECRAFT_BACKUP_SOURCEDIR
		RES=1
	fi

	if ! [ -d "$MINECRAFT_BACKUP_DIR" ]
	then
		echo MINECRAFT_BACKUP_DIR does not exist: $MINECRAFT_BACKUP_DIR
		RES=1
	fi

	if ! [ -d "$MINECRAFT_MAP_WORLDDIR" ]
	then
		echo MINECRAFT_MAP_WORLDDIR does not exist: $MINECRAFT_WORLDDIR
		RES=1
	fi

	if ! [ -d "$MINECRAFT_MAP_DIR" ]
	then
		echo MINECRAF_MAP_DIR does not exist: $MINECRAFT_MAP_DIR
		RES=1
	fi

	return $RES
}

minecraft-has-pid()
{
	[ -e "$MINECRAFT_RUN_PID" ]
	return $?
}

minecraft-is-running()
{
	if ! minecraft-has-pid
	then
		return 1
	fi

	PID=$( cat "$MINECRAFT_RUN_PID" )
	kill -0 $PID > /dev/null 2>&1

	return $?
}

minecraft-clean()
{
	if ! minecraft-is-running && minecraft-has-pid
	then
		echo removing zombie pid-file
		minecraft-clean-pid

		echo removing fifo file
		minecraft-fifo-destroy
		return 1
	fi
}

minecraft-clean-pid()
{
	if ! minecraft-is-running && minecraft-has-pid
	then
		rm "$MINECRAFT_RUN_PID"
	fi
}

minecraft-fifo-read()
{
	while [ -e "$MINECRAFT_RUN_FIFO" ]
	do
		cat "$MINECRAFT_RUN_FIFO"
	done
}

minecraft-fifo-create()
{
	mkfifo "$MINECRAFT_RUN_FIFO"
}

minecraft-fifo-destroy()
{
	rm "$MINECRAFT_RUN_FIFO"
}

minecraft-send-command()
{
	echo $1 > "$MINECRAFT_RUN_FIFO"
}

minecraft-send-message()
{
	echo say $1 > "$MINECRAFT_RUN_FIFO"
}

minecraft-save-off()
{
	minecraft-send-message "save-off due to: $1"
	minecraft-send-command save-off
	minecraft-send-command save-all
	sleep 10
}

minecraft-save-on()
{
	minecraft-send-message "save-on due to: $1"
	minecraft-send-command save-on
}

minecraft-delete-current-server-jar()
{
	local JARFILE

	JARFILE="$( readlink -e minecraft_server.jar )"

	if [ -e "${JARFILE}" ]
	then
		rm -f "${JARFILE}"
	fi
	rm -f minecraft_server.jar
}

minecraft-link-current-server-jar()
{
	JARNAME="$1"

	if ! [ -e "${JARNAME}" ]
	then
		return 1
	fi

	ln -s "${JARNAME}" minecraft_server.jar
}

minecraft-update()
{
	local HTMLOUT XMLOUT JARURL JARFILE

	pushd "$MINECRAFT_RUN_DIR" > /dev/null

	echo "reading html answer of "$MINECRAFT_UPDATE_URL" ..."
	HTMLOUT="$( wget ${MINECRAFT_UPDATE_WGETOPTS} -O - "$MINECRAFT_UPDATE_URL" )" >> "$MINECRAFT_RUN_LOG" 2>&1

	echo "parsing xml ..."
	XMLOUT="$( echo "${HTMLOUT}" | xmllint --recover - )" >> /dev/null 2>&1

	echo -n "parsing download url ... "
	JARURL="$( echo "${XMLOUT}" | xmllint --xpath "${MINECRAFT_UPDATE_XPATH}" - )"
	echo "${JARURL}"

	if [ "${JARURL}" != "" ]
	then
		JARFILE="$( echo "${JARURL}" | grep -e "[^/]*$" -o )"

		echo "deleting old jar file ..."
		minecraft-delete-current-server-jar

		wget "$JARURL" >> "$MINECRAFT_RUN_LOG" 2>&1

		echo "linking minecraft_server.jar to ${JARFILE} ..."
		minecraft-link-current-server-jar "${JARFILE}"
	fi

	popd > /dev/null
}

minecraft-run()
{
	pushd "$MINECRAFT_RUN_DIR" > /dev/null

	minecraft-fifo-create
	minecraft-fifo-read | java -Xmx$MINECRAFT_RUN_MEM -jar minecraft_server.jar nogui >> "$MINECRAFT_RUN_LOG" 2>&1 &
	echo $! > "$MINECRAFT_RUN_PID"

	popd > /dev/null
}

minecraft-stop()
{
	minecraft-save-off "shutdown"
	minecraft-send-command "stop"

	PID=$( cat "$MINECRAFT_RUN_PID" )
	
	i=0
	while kill -0 $PID && [ $i -lt 30 ]
	do
		i=$(( $i +1 ))
		sleep 1
	done > /dev/null 2>&1

	i=0
	while kill $PID && [ $i -lt 30 ]
	do
		echo sending TERM signal...
		i=$(( $i +1 ))
		sleep 1
	done > /dev/null 2>&1

	while kill -9 $PID
	do
		echo sending KILL signal...
		sleep 1
	done > /dev/null 2>&1

	minecraft-fifo-destroy
	minecraft-clean-pid
}

c10t-run()
{
	pushd "$MINECRAFT_MAP_C10TDIR" > /dev/null

	google-api/google-api.sh -w "$MINECRAFT_MAP_WORLDDIR" -o "$MINECRAFT_MAP_DIR" -z 10 -O "-y"

	popd > /dev/null
}

minecraftoverviewer-run()
{
	pushd "$MINECRAFT_MAP_MINECRAFTOVERVIEWERDIR" > /dev/null

	python2 overviewer.py --rendermodes=smooth-lighting,cave "$MINECRAFT_MAP_WORLDDIR" "$MINECRAFT_MAP_DIR"

	popd > /dev/null
}



backup-clean()
{
	pushd "$MINECRAFT_BACKUP_DIR" > /dev/null

	find -maxdepth 1 -mtime +7 | while read file
	do
		rm -rf "$file"
	done

	popd > /dev/null
}

do-start()
{
	if [ "$MINECRAFT_RUN_USER" != "" ] && [ "$(whoami)" != "$MINECRAFT_RUN_USER" ]
	then
		su "$MINECRAFT_RUN_USER" -c "$INVOCATION "${INVOCATIONARGS[@]}""
		return $?
	fi

	if minecraft-is-running
	then
		echo already started
		return 1
	fi

	echo -n starting...
	minecraft-clean
	minecraft-run

	echo pid: $( cat "$MINECRAFT_RUN_PID" )
}

do-stop()
{
	if minecraft-is-running
	then
		echo stopping... pid: $( cat "$MINECRAFT_RUN_PID" )
		minecraft-stop
	else
		echo not running.
	fi

	minecraft-clean

	return 0
}

do-update()
{

	RESTART=0
	if minecraft-is-running
	then
		echo stopping... pid: $( cat "$MINECRAFT_RUN_PID" )

		minecraft-save-off update
		minecraft-stop
		RESTART=1
	fi

	echo updating...
	minecraft-update

	if [ $RESTART -eq 1 ]
	then
		echo restarting...
		minecraft-clean
		minecraft-run

		echo pid: $( cat "$MINECRAFT_RUN_PID" )
	fi

}

do-backup()
{
	echo backing up...

	if minecraft-is-running
	then
		minecraft-save-off "backup"
	fi

	PARENTDIR="$( dirname "$MINECRAFT_BACKUP_SOURCEDIR" )"
        DIRNAME="$( basename "$MINECRAFT_BACKUP_SOURCEDIR" )"

	BACKUPNAME="${MINECRAFT_RUN_WORLD}_$( date +%Y-%m-%d_%H-%M )"
	tar -C "$PARENTDIR" -czf "$MINECRAFT_BACKUP_DIR/${BACKUPNAME}.tar.gz" "$DIRNAME"

	if minecraft-is-running
	then
		minecraft-save-on "backup finished"
	fi
}

do-autoclean-backups()
{
	echo cleaning up backups older than $MINECRAFT_BACKUP_MAXAGE_DAYS days...
	backup-clean	
}

do-create-map()
{
	$MINECRAFT_MAP_FUNC
}

case $1 in
	start)
		if verify-settings
		then
			do-start
		fi
	;;

	stop)
		if verify-settings
		then
			do-stop
		fi
	;;

	update)
		if verify-settings
		then
			do-update
		fi
	;;

	backup)
		if verify-settings
		then
			do-backup
		fi
	;;

	autoclean-backups)
		if verify-settings
		then
			do-autoclean-backups
		fi
	;;

	create-map)
		if verify-settings
		then
			do-create-map
		fi
	;;

	command)
		if verify-settings
		then
			minecraft-send-command "$2"
		fi
	;;

	*)
		usage
	;;
esac
