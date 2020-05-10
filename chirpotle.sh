#!/bin/bash

REPODIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

function chirpotle_check_requirements {
  # Check for Python 3 and set it to $PYTHON
  if [[ -z "$PYTHON" ]]; then
    PYTHON="$(which python3)"
  fi
  if [[ -z "$PYTHON" ]]; then
    PYTHON="$(which python)"
  fi
  if [[ -z "$PYTHON" ]]; then
    echo "No Python 3 installation was found." >&2
    echo "Make sure to intall Python 3 and make it available on PATH or make the PYTHON environment variable point to the executable." >&2
    exit 1
  fi
  if ! ($PYTHON -V 2>&1 | grep "Python 3" > /dev/null); then
    echo "No installation of Python 3 could be found." >&2
    echo "Make sure to intall Python 3 and make it available on PATH." >&2
    exit 1
  fi
  if ! ($PYTHON -c "import venv" &> /dev/null); then
    echo "Missing Python 3 module \"venv\". Please install it and make it available to your python installation." >&2
    echo "Currently using Python from: $PYTHON" >&2
    echo "Use a different python installation by pointing the PYTHON environment variable to the executable." >&2
    exit 1
  fi
}

function chirpotle_check_env {
  if [[ -z "$1" ]]; then
    echo "Name for virtual environment must not be empty." >&2
    echo "Check --envdir / -e argument" >&2
    exit 1
  fi
  if [[ ! -f "$1/bin/activate" ]]; then
    echo "Virtual environment \"$1\" does not exists. You can try to ..." >&2
    echo " ... install ChirpOTLE in the default virtual environment: chirpotle.sh install" >&2
    echo " ... use the --envdir argument to use a custom venv location" >&2
    exit 1
  fi
}

function chirpotle_check_conf {
  if [[ -z "$1" ]]; then
    echo "Configuration directory name must not be empty." >&2
    echo "Check your --confdir / -c argument" >&2
    exit 1
  fi
  if [[ ! -d "$1" ]] || [[ ! -d "$1/hostconf" ]] || [[ ! -d "$1/nodeconf" ]]; then
    echo "The configuration directory does not exists or has an invalid structure. You can try to ..." >&2
    echo " ... install ChirpOTLE with the default configurations: chirpotle.sh install" >&2
    echo " ... check the path again:" >&2
    echo "     $1" >&2
    echo " ... specify a different path using the --confdir argument" >&2
    exit 1
  fi
}

function chirpotle_check_hostconf {
  ABSPATH="$CONFDIR/hostconf/$1.conf"
  if [[ -z "$1" ]]; then echo "Configuration must not be empty." >&2; exit 1; fi
  if [[ ! -e "$ABSPATH" ]]; then
    echo "Configuration $1 does not exist." >&2
    echo "Use \"chirpotle.sh confeditor\" to check for available configurations." >&2
    exit 1
  fi
  echo "$ABSPATH"
}

function chirpotle_confeditor {
  # Enter virtual environment
  source "$ENVDIR/bin/activate"

  # Launch editor
  "$REPODIR/scripts/conf-editor.py" "$CONFDIR"
} # end of chirpotle_confeditor

function chirpotle_deploy {
  # Default parameters
  CONFIGNAME="default"
  INCLUDE_LOCALHOST=0

  # Parameter parsing
  while [[ $# -gt 0 ]]
  do
    KEY="$1"
    case "$KEY" in
        -c|--conf)
          CONFIGNAME="$2"
          shift
          shift
        ;;
        -h|--help)
          echo "  Usage: chirpotle.sh deploy [--conf <config name>] [--help] [--include-localhost]"
          echo ""
          echo "  Setup a virtual environment and install ChirpOTLE and its dependencies."
          echo "  Use the global --env command to specify a custom location for the"
          echo ""
          echo "  IMPORTANT NOTE: The tool will install ChirpOTLE node using root in the"
          echo "    /opt folder of all target hosts and use pip to install Python modules"
          echo "    globally. Make sure that your SSH key is deployed on all nodes as"
          echo "    authorized_key for user root and global installation suits your setup."
          echo ""
          echo "  -c, --conf"
          echo "    The configuration that will be deployed (defaults to \"default\")"
          echo "    Refers to a filename in the conf/hostconf folder, without the .conf"
          echo "    suffix. Use \"chirpotle.sh confeditor\" to edit configurations."
          echo "  -h, --help"
          echo "    Show this help and quit."
          echo "  --include-localhost"
          echo "    By default, the deployment process will skip nodes with their host"
          echo "    property set to \"localhost\", \"127.0.0.1\" or \"::1\", to not install"
          echo "    the software globally (assuming you don't want that on yourcontroller)."
          echo "    This option disables this check."
          exit 0
        ;;
        --include-localhost)
          INCLUDE_LOCALHOST=1
          shift
        ;;
        *)
          echo "Unexpected argument: $KEY" >&2
          echo "Call chirpotle.sh install --help for usage information." >&2
          exit 1
        ;;
    esac
  done

  # Validate config name
  CONFFILE=$(chirpotle_check_hostconf "$CONFIGNAME") || exit 1

  # Enter virtual environment
  source "$ENVDIR/bin/activate"

  # Build and Bundle the TPy Node
  # -----------------------------
  make -C "$REPODIR/submodules/tpy/node" sdist
  if [[ "$?" != "0" ]]; then
    echo "Building TPy Node failed." >&2
    exit 1
  fi

  # Build the companion application for various toolchains
  # ------------------------------------------------------
  # Toolchain for ESP32
  export ESP32_SDK_DIR="$REPODIR/submodules/esp-idf"
  export PATH="$REPODIR/submodules/xtensa-esp32-elf/bin:$PATH"
  APPDIR="$REPODIR/node/companion-app/riot-apps/chirpotle-companion"
  mkdir -p "$APPDIR/dist"

  # Build LoPy4 (UART mode)
  PRECONF=lopy4-uart make -C "$APPDIR" clean all preflash
  if [[ "$?" != "0" ]]; then
    echo "Building the companion application failed for (LoPy4, uart)." >&2
    exit 1
  fi
  (mkdir -p "$APPDIR/dist/lopy4-uart" && cp "$REPODIR/submodules/RIOT/cpu/esp32/bin/bootloader.bin" \
    "$APPDIR/bin/esp32-wroom-32/partitions.csv" "$APPDIR/bin/esp32-wroom-32"/*.bin "$APPDIR/dist/lopy4-uart/")
  if [[ "$?" != "0" ]]; then
    echo "Creating distribution of companion application failed for (LoPy4, uart)." >&2
    exit 1
  fi

  # Deploy
  # ------
  export CONFDIR="$CONFDIR"
  export CONFFILE="$CONFFILE" # require original file for the lookup of node configuration files during deployment
  TMPCONFFILE="$CONFFILE"
  if [[ "$INCLUDE_LOCALHOST" == "0" ]]; then
    TMPCONFFILE="/tmp/$CONFIGNAME-$$.tmp"
    "$REPODIR/scripts/exclude-localhost.py" "$CONFFILE" > "$TMPCONFFILE"
  fi

  # Plain TPy
  tpy deploy -d "$TMPCONFFILE" -p "$REPODIR/submodules/tpy/node/dist/tpynode-latest.tar.gz"
  if [[ "$?" != "0" ]]; then
    echo "Deploying TPy to the nodes failed. Check the output above." >&2
    if [[ ! -z "$TMPCONFFILE" ]] && [[ -f "$TMPCONFFILE" ]]; then rm "$TMPCONFFILE"; fi
    exit 1
  fi

  # Customize TPy for ChirpOTLE
  tpy script -d "$TMPCONFFILE" -s "$REPODIR/scripts/remote-install.sh"
  if [[ "$?" != "0" ]]; then
    echo "Deploying the ChirpOTLE TPy customization to the nodes failed. Check the output above." >&2
    if [[ ! -z "$TMPCONFFILE" ]] && [[ -f "$TMPCONFFILE" ]]; then rm "$TMPCONFFILE"; fi
    exit 1
  fi

  if [[ ! -z "$TMPCONFFILE" ]] && [[ -f "$TMPCONFFILE" ]]; then rm "$TMPCONFFILE"; fi
} # end of chirpotle_deploy

function chirpotle_deploycheck {
  # Default parameters
  CONFIGNAME="default"
  INCLUDE_LOCALHOST=0

  # Parameter parsing
  while [[ $# -gt 0 ]]
  do
    KEY="$1"
    case "$KEY" in
        -c|--conf)
          CONFIGNAME="$2"
          shift
          shift
        ;;
        -h|--help)
          echo "  Usage: chirpotle.sh deploycheck [--conf <config name>] [--help] [--include-localhost]"
          echo ""
          echo "  Checks that the remote nodes fulfill all requirements to run the ChirpOTLE"
          echo "  node, e.g. SSH access and Python installation"
          echo ""
          echo "  IMPORTANT NOTE: The tool will install ChirpOTLE node using root in the"
          echo "    /opt folder of all target hosts and use pip to install Python modules"
          echo "    globally. Make sure that your SSH key is deployed on all nodes as"
          echo "    authorized_key for user root and global installation suits your setup."
          echo ""
          echo "  Optional arguments:"
          echo "  -c, --conf"
          echo "    The configuration that will be used (defaults to \"default\")"
          echo "    Refers to a filename in the conf/hostconf folder, without the .conf"
          echo "    suffix. Use \"chirpotle.sh confeditor\" to edit configurations."
          echo "  -h, --help"
          echo "    Show this help and quit."
          echo "  --include-localhost"
          echo "    By default, the deployment process will skip nodes with their host"
          echo "    property set to \"localhost\", \"127.0.0.1\" or \"::1\", to not install"
          echo "    the software globally (assuming you don't want that on yourcontroller)."
          echo "    This option disables this check."
          exit 0
        ;;
        --include-localhost)
          INCLUDE_LOCALHOST=1
          shift
        ;;
        *)
          echo "Unexpected argument: $KEY" >&2
          echo "Call chirpotle.sh install --help for usage information." >&2
          exit 1
        ;;
    esac
  done

  # Validate config name
  CONFFILE=$(chirpotle_check_hostconf "$CONFIGNAME") || exit 1

  # Create temporary config without the localhosts
  if [[ "$INCLUDE_LOCALHOST" == "0" ]]; then
    TMPCONFFILE="/tmp/$CONFIGNAME-$$.tmp"
    "$REPODIR/scripts/exclude-localhost.py" "$CONFFILE" > "$TMPCONFFILE"
    CONFFILE="$TMPCONFFILE"
  fi

  # Enter virtual environment
  source "$ENVDIR/bin/activate"

  # Run check
  tpy script -d "$CONFFILE" -s "$REPODIR/scripts/remote-checkdep.sh"
  RC=$?
  if [[ ! -z "$TMPCONFFILE" ]] && [[ -f "$TMPCONFFILE" ]]; then rm "$TMPCONFFILE"; fi
  exit $RC
}

function chirpotle_install {
  # Default parameters
  INSTALLMODE=install

  # Parameter parsing
  while [[ $# -gt 0 ]]
  do
    KEY="$1"
    case "$KEY" in
        -d|--dev)
          INSTALLMODE=develop
          shift
        ;;
        -h|--help)
          echo "  Usage: chirpotle.sh install [--dev] [--help]"
          echo ""
          echo "  Setup a virtual environment and install ChirpOTLE and its dependencies."
          echo "  Use the global --env command to specify a custom location for the"
          echo ""
          echo "  Optional arguments:"
          echo "  -d, --dev"
          echo "    Do a development install. This will allow you to edit the libraries"
          echo "    and have the changes immediately available."
          echo "  -h, --help"
          echo "    Show this help and quit."
          exit 0
        ;;
        *)
          echo "Unexpected argument: $KEY" >&2
          echo "Call chirpotle.sh install --help for usage information." >&2
          exit 1
        ;;
    esac
  done

  # Validation
  if [[ -z "$ENVDIR" ]]; then echo "Name for virtual environment must not be empty." >&2; exit 1; fi
  if [[ -e "$ENVDIR" ]]; then echo "Virtual environment \"$ENVDIR\" already exists." >&2; exit 1; fi
  if [[ -z "$CONFDIR" ]]; then echo "Name for the configuration directory must not be empty." >&2; exit 1; fi
  CREATE_CONFDIR=1
  if [[ -e "$CONFDIR" ]]; then
    echo "Configuration directory \"$CONFDIR\" already exists." >&2
    if [[ ! -d "$CONFDIR" ]] || [[ ! -d "$CONFDIR/hostconf" ]] || [[ ! -d "$CONFDIR/nodeconf" ]]; then
      echo "The structure of that directory is invalid. Please specify a non-existing directory or a previously used configuration directory" >&2
      exit 1
    else
      CREATE_CONFDIR=0
      echo "Will not recreate the configuration directory." >&2
    fi
  fi

  # Create the configuration directory from the template
  cp -r "$REPODIR/templates/conf" "$CONFDIR"
  if [[ $? != 0 ]]; then echo "Could not create the configuration directory: $CONFDIR" >&2; exit 1; fi

  # Load TPy if not yet installed
  (cd "$REPODIR" && git submodule update --init submodules/tpy)
  if [[ $? != 0 ]]; then echo "Could not initialize the submodule in submodules/tpy" >&2; exit 1; fi

  # Load RIOT if not yet installed
  (cd "$REPODIR" && git submodule update --init submodules/RIOT)
  if [[ $? != 0 ]]; then echo "Could not initialize the submodule in submodules/RIOT" >&2; exit 1; fi

  # Load ESP IDF if not yet installed
  (cd "$REPODIR" && git submodule update --init submodules/esp-idf && cd "submodules/esp-idf" && git submodule init && git submodule update)
  if [[ $? != 0 ]]; then echo "Could not initialize the submodule in submodules/esp-idf" >&2; exit 1; fi

  # Load xtensa compiler if not yet installed
  (cd "$REPODIR" && git submodule update --init submodules/xtensa-esp32-elf)
  if [[ $? != 0 ]]; then echo "Could not initialize the submodule in submodules/xtensa-esp32-elf" >&2; exit 1; fi

  # Create the virtual environment
  $PYTHON -m venv "$ENVDIR"
  if [[ $? != 0 ]]; then echo "Creating the virtual environment failed." >&2; exit 1; fi

  # Enter the virtual environment. From here on, we use python instead of the global $PYTHON
  source "$ENVDIR/bin/activate"

  # Install TPy
  (cd "$REPODIR/submodules/tpy/controller" && python setup.py $INSTALLMODE)
  if [[ $? != 0 ]]; then echo "Installing TPy Controller failed. Check the output above." >&2; exit 1; fi

  # Install TPy Node for localnode
  (cd "$REPODIR/submodules/tpy/node" && python setup.py $INSTALLMODE && pip install -r "$REPODIR/node/remote-modules/requirements.txt")
  if [[ $? != 0 ]]; then echo "Installing TPy Node failed. Check the output above." >&2; exit 1; fi
  
  # Install libraries and controller
  (cd "$REPODIR/controller/chirpotle" && python setup.py $INSTALLMODE)
  if [[ $? != 0 ]]; then echo "Installing requirements failed. Check the output above." >&2; exit 1; fi

  # Other tools required by the controller
  pip install pyserial # Flashing of devices
  if [[ $? != 0 ]]; then echo "Installing requirements failed. Check the output above." >&2; exit 1; fi

} # end of chirpotle_install

function chirpotle_interactive {
  # Default parameters
  CONFIGNAME="default"

  # Parameter parsing
  while [[ $# -gt 0 ]]
  do
    KEY="$1"
    case "$KEY" in
        -c|--conf)
          CONFIGNAME="$2"
          shift
          shift
        ;;
        -h|--help)
          echo "  Usage: chirpotle.sh [...] interactive [--conf <config name>] [--help]"
          echo ""
          echo "  Get an interactive Python REPL with nodes and control objects already set up."
          echo ""
          echo "  Optional arguments:"
          echo "  -c, --conf"
          echo "    The configuration that will be used (defaults to \"default\")"
          echo "    Refers to a filename in the conf/hostconf folder, without the .conf"
          echo "    suffix. Use \"chirpotle.sh confeditor\" to edit configurations."
          echo "  --help"
          echo "    Show this help and quit."
          exit 0
        ;;
        *)
          echo "Unexpected argument: $KEY" >&2
          echo "Call chirpotle.sh install --help for usage information." >&2
          exit 1
        ;;
    esac
  done

  # Validate config name
  export CONFFILE=$(chirpotle_check_hostconf "$CONFIGNAME") || exit 1

  # Enter virtual environment
  source "$ENVDIR/bin/activate"

  # Run the script
  "$REPODIR/scripts/interactive-session.py"

} # end of chirpotle_interactive

function chirpotle_localnode {
  # Default parameters
  NODECONF=""

  while [[ $# -gt 0 ]]
  do
    KEY="$1"
    case "$KEY" in
        -c|--conf)
          CONFIGNAME="$2"
          shift
          shift
        ;;
        -h|--help)
          echo "  Usage: chirpotle.sh [...] chirpotle [--help] <node-profile>"
          echo ""
          echo "  Run a ChirpOTLE node on your controller. This function allows you running a"
          echo "  local node without running the usual deploy process on your local machine, and"
          echo "  without installing all tools globally. Make sure that your configuration still"
          echo "  contains an entry for localhost. The \"deploy\" and \"restartnodes\" task will"
          echo "  ignore entries for localhost, if you do not use the --include-localhost flag."
          echo ""
          echo "  Note: If you're connecting an MCU to your local machine and do not use the"
          echo "  default deployment process, you need to flash the companion application"
          echo "  manually. See node/companion-application/riot-apps/chirpotle-companion for"
          echo "  details."
          echo ""
          echo "  Required arguments:"
          echo "  node-profile"
          echo "    Name of the node profile to use. Edit them using \"chirpotle.sh confeditor\"."
          echo "    Basically refers to a file in your conf/nodeconf folder (without the file"
          echo "    extension)."
          echo ""
          echo "  Optional arguments:"
          echo "  --help"
          echo "    Show this help and quit."
          exit 0
        ;;
        *)
          if [[ -z "$NODECONF" ]]; then
            NODECONF="$KEY"
            shift
          else
            echo "Unexpected argument: $KEY" >&2
            echo "Call chirpotle.sh install --help for usage information." >&2
            exit 1
          fi
        ;;
    esac
  done

  # Validate node configuration
  if [[ -z "$NODECONF" ]]; then echo "No node configuration was specified. See \"chirpotle.sh localnode --help\" for details."; exit 1; fi
  NODECONFFILE="$CONFDIR/nodeconf/$NODECONF.conf"
  if [[ ! -f "$NODECONFFILE" ]]; then echo "Node configuration \"$NODECONF\" does not exist."; exit 1; fi

  # Replace the additional modules dir
  TMPCONFFILE="/tmp/node-$$.conf"
  sed -E "s#^module_path *=.*\$#module_path = $REPODIR/node/remote-modules/#" "$NODECONFFILE" > "$TMPCONFFILE"

  # Enter virtual environment
  source "$ENVDIR/bin/activate"

  # Run the node in foreground
  tpynode run -c "$TMPCONFFILE"

  if [[ ! -z "$TMPCONFFILE" ]] && [[ -f "$TMPCONFFILE" ]]; then rm "$TMPCONFFILE"; fi
} # end of chirpotle_localnode

# Run a script in the virtual environment
function chirpotle_run {
  # Default parameters
  CONFIGNAME="default"
  POSITIONAL=()
  SCRIPTNAME=""

  # Parameter parsing
  while [[ $# -gt 0 ]] && [[ -z "$SCRIPTNAME" ]]; do
    KEY="$1"
    case "$KEY" in
        -c|--conf)
          CONFIGNAME="$2"
          shift
          shift
        ;;
        -h|--help)
          echo "  Usage: chirpotle.sh [...] run [--conf <config name>] [--help] <script.py> [scriptargs...]"
          echo ""
          echo "  Setup the framework and run a script. The devices can be accessed in the"
          echo "  script using the following snippet:"
          echo ""
          echo "      from chirpotle.context import tpy_from_context"
          echo "      tc, devices = tpy_from_context()"
          echo ""
          echo "  The first unknown argument is treated as script name, and all following"
          echo "  arguments are passed to the script."
          echo ""
          echo "  Optional arguments:"
          echo "  -c, --conf"
          echo "    The configuration that will be used (defaults to \"default\")"
          echo "    Refers to a filename in the conf/hostconf folder, without the .conf"
          echo "    suffix. Use \"chirpotle.sh confeditor\" to edit configurations."
          echo "  -h, --help"
          echo "    Show this help and quit."
          exit 0
        ;;
        *)
          # First "unknown" argument is script name ...
          SCRIPTNAME="$KEY"
          shift
        ;;
    esac
  done
  # ... all other arguments (if any) are passed to the script as positional args
  if [[ $# -gt 0 ]]; then
    POSITIONAL+="$@"
  fi

  # Validate config name and get absolute path
  export CONFFILE=$(chirpotle_check_hostconf "$CONFIGNAME") || exit 1

  # Enter virtual environment
  source "$ENVDIR/bin/activate"

  # Run the script
  python "$SCRIPTNAME" "${POSITIONAL[@]}"

} # end of chirpotle_run

function chirpotle_restartnodes {
  # Default parameters
  CONFIGNAME="default"
  INCLUDE_LOCALHOST=0

  # Parameter parsing
  while [[ $# -gt 0 ]]
  do
    KEY="$1"
    case "$KEY" in
        -c|--conf)
          CONFIGNAME="$2"
          shift
          shift
        ;;
        -h|--help)
          echo "  Usage: chirpotle.sh [...] restartnodes [--conf <config name>] [--help] [--include-localhost]"
          echo ""
          echo "  (Re)start all ChirpOTLE nodes which are configured in a configuration."
          echo ""
          echo "  Optional arguments:"
          echo "  -c, --conf"
          echo "    The configuration that will be used (defaults to \"default\")"
          echo "    Refers to a filename in the conf/hostconf folder, without the .conf"
          echo "    suffix. Use \"chirpotle.sh confeditor\" to edit configurations."
          echo "  -h, --help"
          echo "    Show this help and quit."
          echo "  --include-localhost"
          echo "    By default, the deployment process will skip nodes with their host"
          echo "    property set to \"localhost\", \"127.0.0.1\" or \"::1\", to not install"
          echo "    the software globally (assuming you don't want that on yourcontroller)."
          echo "    This option disables this check."
          exit 0
        ;;
        *)
          echo "Invalid argument: $1"
          exit 1
        ;;
    esac
  done

  # Validate config name and get absolute path
  CONFFILE=$(chirpotle_check_hostconf "$CONFIGNAME") || exit 1

  # Create temporary config without the localhosts
  if [[ "$INCLUDE_LOCALHOST" == "0" ]]; then
    TMPCONFFILE="/tmp/$CONFIGNAME-$$.tmp"
    "$REPODIR/scripts/exclude-localhost.py" "$CONFFILE" > "$TMPCONFFILE"
    CONFFILE="$TMPCONFFILE"
  fi

  # Enter virtual environment
  source "$ENVDIR/bin/activate"

  tpy restart -d "$CONFFILE"
  RC=$?
  if [[ ! -z "$TMPCONFFILE" ]] && [[ -f "$TMPCONFFILE" ]]; then rm "$TMPCONFFILE"; fi
  exit $RC
} # end of chirpotle_tpy

function chirpotle_tpy {
  # Enter virtual environment
  source "$ENVDIR/bin/activate"

  tpy "$@"
} # end of chirpotle_tpy


function chirpotle_usage {
  echo "  Usage: chirpotle.sh [--confdir <dir>] [--envdir <dir>] <command> [--help]"
  echo ""
  echo "  Where <command> is one of:"
  echo "    confeditor   - Launch interactive configration editor"
  echo "    deploy       - Deploy ChirpOTLE to nodes"
  echo "    deploycheck  - Check requirements on ChirpOTLE nodes"
  echo "    help         - Show this information"
  echo "    install      - Install controller on this host in a virtual environment"
  echo "    interactive  - Run an interactive evaluation session"
  echo "    localnode    - Start a local instance of ChirpOTLE node"
  echo "    restartnodes - (Re)start the remote ChirpOTLE nodes"
  echo "    run          - Run a script in the virtual environment"
  echo "    tpy          - Run a TPy command directly"
  echo ""
  echo "  Global arguments:"
  echo "  -c, --confdir <dir>"
  echo "    Directory to store configuration files, defaults to chirpotle/conf."
  echo "    Configurations can be managed manually or using the confeditor command."
  echo "  -e, --envdir <dir>"
  echo "    The virtual environment to use, defaults to chirpotle/env."
  echo "    Create and populate it using the install command."
  echo ""
  echo "  Use chirpotle.sh <command> --help to learn about command-specific options."
  exit $RC
}

# Basic setup. Check if we have the required tools available on PATH, otherwise
# abort and instruct the user to install them using the software manager of the
# host OS
chirpotle_check_requirements
VERSION=$("$PYTHON" "$REPODIR/controller/chirpotle/setup.py" "--version")
echo "ChirpOTLE - A LoRaWAN Security Evaluation Framework"
echo "            Controller Version $VERSION"
echo ""

# Main command selection. Pass global arguments up to the command keyword, then
# continue with the command-specific sub-parser
ENVDIR="$REPODIR/env"
CONFDIR="$REPODIR/conf"
ACTION=
RC=0
while [[ $# -gt 0 ]] && [[ -z "$ACTION" ]]
do
  case "$1" in
    confeditor)
      shift
      ACTION=chirpotle_confeditor
    ;;
    deploy)
      shift
      ACTION=chirpotle_deploy
    ;;
    deploycheck)
      shift
      ACTION=chirpotle_deploycheck
    ;;
    install)
      shift
      ACTION=chirpotle_install
    ;;
    interactive)
      shift
      ACTION=chirpotle_interactive
    ;;
    localnode)
      shift
      ACTION=chirpotle_localnode
    ;;
    restartnodes)
      shift
      ACTION=chirpotle_restartnodes
    ;;
    run)
      shift
      ACTION=chirpotle_run
    ;;
    tpy)
      shift
      ACTION=chirpotle_tpy
    ;;
    --help|help)
      shift
      ACTION=chirpotle_usage
    ;;
    -c|--confdir)
      CONFDIR="$2"
      shift
      shift
    ;;
    -e|--envdir)
      ENVDIR="$2"
      shift
      shift
    ;;
    *)
      ACTION=chirpotle_usage
      RC=1
    ;;
  esac
done

# Default to usage info with RC=1
if [[ -z "$ACTION" ]]; then
  ACTION=chirpotle_usage
  RC=1
fi

# Validate the virtual environment
if [[ "$ACTION" != "chirpotle_usage" ]] && [[ "$ACTION" != "chirpotle_install" ]]; then
  chirpotle_check_env "$ENVDIR"
  chirpotle_check_conf "$CONFDIR"
fi

# Run the action with the remaining parameters passed to the sub-parser
$ACTION "$@"
