#!/bin/bash
##########################################################
## Get the topology of your MongoDB sharded cluster	##
## Need JQ libraray to work			    	##
## Date format is DD/MM/YYYY HH:MM:SS			##
##########################################################

# Output formating
RED=`tput setaf 1`
GREEN=`tput setaf 2`
YELLOW=`tput setaf 3`
RESET=`tput sgr0`

# Connection informations
CLUSTERADMINUSR=""
CLUSTERADMINPWD=""
CLUSTERAUTHDB=""
LOCALADMINUSR=""
LOCALADMINPWD=""
LOCALAUTHDB=""
FIRSTMONGOS=""

# Execute commands on mongos (router)
RunOnMongos(){
	local TARGET=$1
	local COMMANDS=$2
	local RETSTRING=$3
	local MONGOPARAMS=()
	local MONGOOUTPUT
	
	MONGOPARAMS+=("--quiet")
	MONGOPARAMS+=("-u" "${CLUSTERADMINUSR}")
	MONGOPARAMS+=("-p" "${CLUSTERADMINPWD}")
	MONGOPARAMS+=("--authenticationDatabase" "${CLUSTERAUTHDB}")
 	MONGOPARAMS+=("--host" "${TARGET}")
    	MONGOPARAMS+=("--eval")
	if [[ -z ${RETSTRING} || ${RETSTRING} -eq 0 ]];then
    		MONGOPARAMS+=("printjson(${COMMANDS})")
	elif [[ ${RETSTRING} -eq 1 ]];then
		MONGOPARAMS+=("print(${COMMANDS})")
	else
		MONGOPARAMS+=("${COMMANDS}")
	fi
	MONGOOUTPUT=$(mongo "${MONGOPARAMS[@]}" 2>/dev/null)
	echo -e "${MONGOOUTPUT}"
}

# Execute commands on mongo (replica set member)
RunOnMongo(){
        local TARGET=$1
        local COMMANDS=$2
	local RETSTRING=$3
        local MONGOPARAMS=()
	local MONGOOUTPUT

        MONGOPARAMS+=("--quiet")
        MONGOPARAMS+=("-u" "${LOCALADMINUSR}")
        MONGOPARAMS+=("-p" "${LOCALADMINPWD}")
        MONGOPARAMS+=("--authenticationDatabase" "${LOCALAUTHDB}")
        MONGOPARAMS+=("--host" "${TARGET}")
        MONGOPARAMS+=("--eval")
	if [[ -z ${RETSTRING} || ${RETSTRING} -eq 0 ]];then
                MONGOPARAMS+=("printjson(${COMMANDS})")
	elif [[ ${RETSTRING} -eq 1 ]];then
                MONGOPARAMS+=("print(${COMMANDS})")
        else
                MONGOPARAMS+=("${COMMANDS}")
        fi
	MONGOOUTPUT=$(mongo "${MONGOPARAMS[@]}" 2>/dev/null)
        echo -e "${MONGOOUTPUT}"
}

# Simple connectivity test
TestConnection(){
	RETURN=$(timeout 5 mongo --host $1 --eval "print("1")" --quiet 2>/dev/null)
	RET=$?
	return $RET
}

# Get the list of config replica set members
GetConfigDB(){
	echo -e "#### Config DB list ####"
	CONFIGDB=$(RunOnMongos "${FIRSTMONGOS}" 'db.getSiblingDB("admin").runCommand("getShardMap").map.config' "1"|awk -F "/" '{print $2}')
	CONFIGDBARRAY=(${CONFIGDB//,/ })
	
	PRIMARYFOUND=0
	PRIMARY=""
	
	for configdb in ${CONFIGDBARRAY[*]};do

		STATUS=$(TestConnection ${configdb})

		if [[ ${PRIMARYFOUND} -eq 0 && ${STATUS} -eq 0 ]];then
			PRIMARY=$(RunOnMongo "${configdb}" 'db.runCommand("ismaster").primary' "1")
			PRIMARYFOUND=1
		fi

		if [[ ${STATUS} -eq 0 ]];then
			STATUSSTR="${GREEN}UP${RESET}"
		elif [[ ${STATUS} -eq 124  ]];then
			STATUSSTR="${YELLOW}TIMEOUT${RESET}"
		else
			STATUSSTR="${RED}DOWN${RESET}"
		fi
		
		if [[ ${configdb} == ${PRIMARY} ]];then
			echo -e "${configdb} : PRIMARY : ${STATUSSTR}"
		elif [[ ${configdb} != ${PRIMARY} && ${STATUS} -ne 0 ]];then
			echo -e "${configdb} : UNKNOWN : ${STATUSSTR}"
		else
			echo -e "${configdb} : SECONDARY : ${STATUSSTR}"
		fi
	done

	BALANCERSTATUS=$(RunOnMongos "${FIRSTMONGOS}" 'sh.getBalancerState()' "1")
	echo -e "Balancer enabled : ${BALANCERSTATUS}"
	echo
	
}

# Get the list of all mongos (routers)
# If one of the routers has been removed, it can be marked "DOWN" because MongoDB keeps track of all the mongos in the "config.mongos" collection.

GetRouters(){
	echo -e "#### Mongos list ####"
	MONGOS=$(RunOnMongos "${FIRSTMONGOS}" 'db.getSiblingDB("config").mongos.find({},{"_id":1}).forEach(printjson)' "2")
	MONGOS=$(echo -e "${MONGOS}"|jq -r "._id")
	for mongos in ${MONGOS[*]};do
		STATUS=$(TestConnection ${mongos})
		if [[ ${STATUS} -eq 0 ]];then
                	echo -e "${mongos} : ${GREEN}UP${RESET}"
		elif [[ ${STATUS} -eq 124  ]];then
                        echo -e "${mongos} : ${YELLOW}TIMEOUT${RESET}"
                else
                        echo -e "${mongos} : ${RED}DOWN${RESET}"
                fi
	done
	echo -e ""
}


# Get list of all replica set members of each shard

GetShards(){
	echo -e "#### Shards list ####"
	SHARDS=$(RunOnMongos "${FIRSTMONGOS}" 'db.getSiblingDB("config").shards.find({},{"_id":1,"host":1}).forEach(printjson)' "2")
	SHARDSNAMES=$(echo -e "${SHARDS}"|jq -r '._id')
	
	for shard in ${SHARDSNAMES};do
		shardlist=$(echo -e "${SHARDS}"|jq -r --arg shard "$shard" 'select(._id==$shard).host'|awk -F "/" '{print $2}')
		shardlistarrary=${shardlist//,/ }

		PRIMARYFOUND=0
        	PRIMARY=""
		ARBITERFOUND=0
		ARBITER=""
		echo -e "[Shard : $shard]"
		for shar in ${shardlistarrary[*]};do
		
			STATUS=$(TestConnection ${shar})
                	if [[ ${STATUS} -eq 0 ]];then
                        	STATUSSTR="${GREEN}UP${RESET}"
			elif [[ ${STATUS} -eq 124  ]];then
                        	STATUSSTR="${YELLOW}TIMEOUT${RESET}"
                	else
                        	STATUSSTR="${RED}DOWN${RESET}"
                	fi

			# Check if an arbiter is set for the replica set
			if [[ ${ARBITERFOUND} -eq 0 && ${STATUS} -eq 0 ]];then
				ARBITER=$(RunOnMongo "${shar}" 'db.runCommand("ismaster").arbiters')
				ARBITERFOUND=1
				if [[ ${ARBITER} != "undefined" ]];then
					ARBITER=$(echo -e "${ARBITER}"|jq -r '.[]')
					ARBSTATUS=$(TestConnection ${ARBITER})
					if [[ ${ARBSTATUS} -eq 0 ]];then
	                                	STATUSSTRARB="${GREEN}UP${RESET}"
        	                	elif [[ ${ARBSTATUS} -eq 124  ]];then
                	               		STATUSSTRARB="${YELLOW}TIMEOUT${RESET}"
                        		else
                                		STATUSSTRARB="${RED}DOWN${RESET}"
                        		fi
					echo -e "$ARBITER : ARBITER : ${STATUSSTRARB}"
				fi
			fi		

			if [[ ${PRIMARYFOUND} -eq 0 && ${STATUS} -eq 0 ]];then
				PRIMARY=$(RunOnMongo "${shar}" 'db.runCommand("ismaster").primary' "1")
                        	PRIMARYFOUND=1
                	fi

			

                	if [[ ${shar} == ${PRIMARY} ]];then
				echo -e "${shar} : PRIMARY : ${STATUSSTR}"
			elif [[ ${shar} != ${PRIMARY} && ${STATUS} -ne 0 ]];then
                        	echo -e "${shar} : ${YELLOW}UNKNOWN${YELLOW} : ${STATUSSTR}"
                	else
				echo -e "${shar} : SECONDARY : ${STATUSSTR}"
                	fi
			
		done

		echo -e ""
		if [[ ${PRIMARYFOUND} -gt 0 ]];then
			# Get the date of the last switch between primary/secondary
			LASTSWITCH=$(RunOnMongo "${PRIMARY}" "var d=db.runCommand('isMaster').electionId.getTimestamp();var yyyy = d.getFullYear();var mm = (d.getMonth() + 101).toString().slice(-2);var dd = (d.getDate() + 100).toString().slice(-2);var hh = ('0'+d.getHours()).slice(-2);var mi = ('0'+d.getMinutes()).slice(-2);var ss = ('0'+d.getSeconds()).slice(-2);print(dd + '/' + mm+'/'+yyyy+' '+hh+':'+mi+':'+ss);" "2")
			
			# Get current apply lag
			APPLYLAG=$(RunOnMongo "${PRIMARY}" "rs.status().members.filter(r=>r.state===2).forEach(function(element){var primelem=rs.status().members.find(r=>r.state===1);var prim=primelem.optime.t;var primname=primelem.name;var sec=rs.status().members.find(r=>r.name===element.name).optime.t;print(element.name+' is '+(prim-sec)+' second(s) behind primary '+primname)});" "2")

			# Get oplog window
			OPLOGWINDOW=$(RunOnMongo "${PRIMARY}" "var seconds = parseInt(db.getReplicationInfo().timeDiff, 10);var days = Math.floor(seconds / (3600*24));var seconds = seconds - (days*3600*24);var hrs = Math.floor(seconds / 3600);var seconds  = seconds - (hrs*3600);var mnts = Math.floor(seconds / 60);var seconds = seconds - (mnts*60);print(days+' days, '+hrs+' Hours, '+mnts+' Minutes, '+seconds+' Seconds');" "2")

			echo -e "--Last switch: ${LASTSWITCH}"
			echo -e "--Apply lag:\n${APPLYLAG}"
			echo -e "--Oplog window: ${OPLOGWINDOW}"
		else
			echo -e "--Last switch : UNKNOWN"
			echo -e "--Apply lag : UNKNOWN"
			echo -e "--Oplog window : UNKNOWN"
		fi
		echo -e ""
	done
}


# We need to be sure the first mongos (FIRSTMONGOS variable) is UP
FIRSTMONGOSSTATUS=$(TestConnection "${FIRSTMONGOS}")
if [[ ${STATUS} -ne 0 ]];then
	echo -e "${FIRSTMONGOS} no available. Exit"
	exit 1;
fi

GetConfigDB
GetRouters
GetShards
exit 0;
