#!/bin/bash
######################################
# Ce script va charger les variables 
# d'environnement nécessaires
# puis lancer le docker-compose up -d
if [ ! -f ./vars ]; then
    echo "Le fichier vars n'a pas été trouvé"
    echo "Vous devez copier le fichier vars-default en vars"
    echo "Puis l'éditer selon vos besoins"
    exit 1
else
    source ./vars
fi
# test des variables
for myvar in BASE_URL ADMIN_URL PASSWD_FILE MAIL_ADDRESS CONFIG_DIR DATA_DIR
do
    if [ -z "${!myvar}" ]; then
      echo "La variable $myvar n'a pas été renseignée"
      echo "Vérifiez votre fichier vars avant de continuer"
      exit 1
    fi

done

##########################
# Définition des fonctions
##########################
# Start
# Démarre la seedbox
function start {
  docker-compose $(for file in `ls *yml`;do echo "-f $file";done) up -d
}

############################
# stop
# Arrête la seedbox
function stop {
  docker-compose $(for file in `ls *yml`;do echo "-f $file";done) down --remove-orphans
}

############################
# affiche
# Affiche un message à l'écran, soit en whiptail pour interactif
# soit directement en echo
function affiche {
     if [ ${INTERACTIVE} -eq 0 ]
    then
        echo "$1"
    else
        whiptail --msgbox "$1" 20 78
        return
    fi
}

############################
# usage
# Affiche l'aide
function usage {
read -d '' USAGE << EOF
Seedbox
Usage :
sans paramètre => lancement en interactif
--start   => lancement de la seedbox
--stop    => arrête la seedbox
--restart => redémarre la seedbox
--help    => affiche l'aide
--adduser toto => crée l'utilisateur toto
--deluser toto => supprime l'utilisateur toto (sans confirmation, les données sont conservées)
--maj     => met à jour tous les containers
--help    => affiche cette aide
EOF
    affiche "$USAGE"
}

############################
# deluser
# Supprime un user
# Ne supprime ni sa conf ni ses données
function deluser() {
  username=$1
  # Suppression de l'utilisateur ftp
  docker exec -i pure_ftp_seedbox /bin/bash << EOC
    pure-pw userdel ${username} -f /etc/pure-ftpd/passwd/pureftpd.passwd
EOC
  # Suppression des fichiers de configuration"
  rm -f ${username}.yml
  # Suppression du fichier des mots de passe"
  htpasswd -D ${PASSWD_FILE} ${username}
read -d '' DELUSER << EOF
Suppression de l'utilisateur terminée
=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-
Les dossiers de l'utilisateur ont été conservés
EOF
    affiche "$DELUSER"
    affiche_restart
}

############################
# affiche_restart
# Affiche le message comme quoi il faut redémarrer
function affiche_restart() {
    read -d '' RESULT << EOF
=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-
IMPORTANT
Vous devez redémarrer la seedbox pour appliquer les changements
=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-
EOF
    affiche "$RESULT"
}

############################
# adduser
# prend en parametre le user à rajouter
function adduser() {
  username=$1
  if [ -f ${username}.yml ]
  then
    read -d '' RESULT << EOF
#############################
# Utilisateur déjà existant #
#############################
# Si vous voulez le recréer
# Merci de le supprimer avant
EOF
    affiche "$RESULT"
  else
    if [ ${INTERACTIVE} -eq 0 ]
    then
        echo "Entrez son password, suivi de entrée"
        read mypassword
    else
        mypassword=$(whiptail --passwordbox "Entrez le password de l'utilisateur ${username}" 8 78 --title "password dialog" 3>&1 1>&2 2>&3)
        exitstatus=$?
        if [ ${exitstatus} != 0 ]; then
            whiptail --msgbox "Action annulée" --title "Action annulée" 20 78
            return
        fi

    fi
    htpasswd -b ${PASSWD_FILE} ${username} ${mypassword}
    # recherche du port à ouvrir pour rutorrent
    declare -i myport
    myport=45001
    for file in `ls *yml`
    do
      current_port=$(grep UserPort ${file} | awk -F ':' '{print $1}'| awk -F '"' '{print $2}')
      if [ ! -z "$current_port" ]
      then
        if (( ${current_port} >= ${myport} ))
        then
          myport=$(( current_port + 1 ))
        fi
      fi
    done
    #echo "Le port pour rutorrent sera le $myport"
    sed "s/{{ user }}/${username}/g" user.template | sed "s/{{ port }}/${myport}/g" > ${username}.yml
    #echo "Ajout de l'utilisateur pour le FTP"
    docker exec -i pure_ftp_seedbox /bin/bash << EOF
( echo ${mypassword} ; echo ${mypassword} )|pure-pw useradd ${username} -f /etc/pure-ftpd/passwd/pureftpd.passwd -m -u ftpuser -d /home/ftpusers/${username}/data
EOF
    # On crée les répertoires
    # Cela permet de s'assurer qu'ils ne seront pas créés par docker
    # avec les droits root
    mkdir -p ${CONFIG_DIR}/${username}
    mkdir -p ${DATA_DIR}/${username}
read -d '' RESULT << EOF
L\'utilisateur a été créé.
Adresse de rutorrent : https://${BASE_URL}/${username}_rutorrent/
Adresse de sickrage : https://${BASE_URL}/${username}_sickrage/
Adresse de medusa : https://${BASE_URL}/${username}_medusa/
Adresse de couchpotato : https://${BASE_URL}/${username}_couchpotato
EOF
    affiche "$RESULT"
    affiche_restart
  fi
}
# maj => met à jour tous les containers
function maj {
    docker-compose $(for file in `ls *yml`;do echo "-f $file";done) pull
    affiche_restart
}
# create_admin
function create_admin {
  ###################################
  # Cette fonction ne va se lancer
  # que pour créer un admin
  echo "Vous n'avez pas encore de compte administrateur pour cette seedbox"
  echo "Il faut en créer un pour pouvoir continuer."
  echo "Saisissez le mot de passe du compte :"
  read adminpassword
  if [ ! -f ${PASSWD_FILE} ] 
  then
    htpasswd -bc ${PASSWD_FILE} admin ${adminpassword}
  else
    htpasswd -b ${PASSWD_FILE} admin ${adminpassword}
  fi
  export passwd_admin=${adminpassword}
  start
  echo "Le compte admin a été créé."
  echo "Vous devez maintenant vous connecter sur https://${ADMIN_URL}/portainer/ et choisir un mot de passe pour sécuriser la partie portainer"

}
function interactive {
  INTERACTIVE=1
  while [ 1 ]
    do
    CHOICE=$(
    whiptail --title "Seedbox docker" --menu "Faites votre choix" 16 100 9 \
        "start" "Démarrer la seedbox."   \
        "stop" "Arrêter la seedbox."  \
        "restart" "Redémarrer la seedbox." \
        "adduser" "Ajouter un utilisateur." \
        "maj" "Mise à jour."\
        "help" "Afficher l'aide." \
        "quit" "Quitter cette interface"  3>&2 2>&1 1>&3
    )
    case ${CHOICE} in
        "start")
            start
        ;;
        "stop")
            stop
        ;;

        "restart")
            stop
            start
        ;;

        "adduser")
            USERNAME=$(whiptail --inputbox "Entrez le nom d'utilisateur" --title "Choix utilisateur" 10 78 3>&1 1>&2 2>&3)
            exitstatus=$?
            if [ ${exitstatus} != 0 ]; then
                whiptail --msgbox "Action annulée" --title "Action annulée" 20 78
                return
            fi
            adduser ${USERNAME}
        ;;

        "maj")
            maj
        ;;

        "help")
            usage
        ;;

        "quit") exit
            ;;
    esac
    done
  exit 0
}
#######################################
# FIN DE DEFINITION DES FONCTIONS
#######################################

#######################################
# Variables
export MYUID=$(id -u)
export MYGID=$(id -g)
# Gestion de password
for line in $(cat ${PASSWD_FILE})
do
  user=$(echo ${line} | awk -F':' '{print $1}')
  pass=$(echo ${line} | awk -F':' '{print $2}')
  export passwd_${user}=${pass}
done
INTERACTIVE=0 # on met le interactive à 0, on changera plus tard si besoin

#######################
# LANCEMENT PRINCIPAL #
#######################

#########################################
# On vérifie que le user est bien dans le groupe docker
if groups ${USER} | grep &>/dev/null '\bdocker\b'; then
    :
else
    echo "#####################################"
    echo "ERREUR"
    echo "Votre utilisateur n'est pas dans le groupe docker"
    echo "Lancez la commande"
    echo "sudo usermod -aG docker ${USER}"
    echo "Puis déconnectez et reconnectez vous"
    exit 1
fi

#########################################
# Avant de passer à la suite, on va
# regarder s'il y a un admin
if [ ! -f ${PASSWD_FILE} ]
then
  create_admin
  exit 0
fi
if ! grep -q admin ${PASSWD_FILE}
then
  create_admin
  exit 0
fi

#########################################
# Options de lancement
OPTS=`getopt -o vhns: --long start,stop,restart,help,maj,adduser:,deluser:,interactive -n 'parse-options' -- "$@"`

if [ $? != 0 ] ; then echo "Failed parsing options." >&2 ; exit 1 ; fi

eval set -- "${OPTS}"
while true ; do
  case "$1" in
    --interactive)
      interactive
      exit 0
      ;;
    --start)
      echo "Démarrage de la seedbox"
      echo "----------------------------------"
      start
      exit 0
      ;;
    --stop)
      stop
      exit 0
      ;;
    --restart)
      stop
      start
      exit 0
      ;;
    --help)
      usage
      exit 0
      ;;        
    --adduser)
      adduser $2
      exit 0
      ;;
    --deluser)
      echo "Suppression de l'utilisateur $2"
      deluser $2
      exit 0
      ;;
    --maj)
      echo "Mise à jour des containers"
      maj
      exit 0
      ;;
      --) shift ; break ;;
      *) echo "Internal error!" ; exit 1 ;;
  esac
done

# On n'a passé aucun paramètre, on en déduit qu'il faut partir en interactif
interactive
