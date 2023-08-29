#!/usr/bin/bash
# this script serves a purpose of building, deploying and invoking functions with specified arguments used for simple
# testing.
# -- by gauron99

ROOT_DIR="$PWD"
FUNC_REGISTRY="docker.io/4141gauron3268"
NAME_APENDIX="-build-deploy-generated"


builder_arg_pack="pack"
#builders arguments (go&rust&springboot dont have s2i)
builder_arg_s2i="s2i"


# Array of directory names (this is used as base length in main for cycle)
DIRECTORY_NAMES_BASE=( "go" "python" "node" "quarkus" "rust" "springboot" "typescript" )
# DIRECTORY_NAMES_BASE=( "go" ) #for testing
S2I_SKIP_DIRECTORIES=("go" "rust" "springboot")

DIRECTORY_NAMES_BASE_LENGTH="${#DIRECTORY_NAMES_BASE[@]}"
S2I_SKIP_DIRECTORIES_LENGTH="${#S2I_SKIP_DIRECTORIES[@]}"

# Color codes
COLOR_RED="\033[0;31m"
COLOR_GREEN="\033[0;32m"
COLOR_BLUE="\033[0;34m"
COLOR_YELLOW="\033[0;33m"
COLOR_RESET="\033[0m"

SKIP_TRUE=1
SKIP_FALSE=0

# Variables for errors
create_errors=0
build_errors=0
deploy_errors=0
errors=()

create_skipped=0
build_skipped=0
deploy_skipped=0

## TODO: SET THIS TO WHAT YOU WANT TO TEST
############################### DEPLOY ARGUMENT ################################
##### set if --remote should be used or not
CURRENT_DEPLOY_ARG="--remote"
# CURRENT_DEPLOY_ARG=

########################## BUILDER ARUMENT --builder= ##########################
#default
CURRENT_BUILD_ARG=$builder_arg_pack
if [ "$#" -ge 1 ] && [ "$1" == "s2i" ];then
  CURRENT_BUILD_ARG=$builder_arg_s2i
elif [ "$#" -ge 1 ] && [ "$1" == "pack" ];then
  CURRENT_BUILD_ARG=$builder_arg_pack
elif [ "$#" -ge 1 ] && [ "$1" == "host" ];then
  echo -e "${COLOR_RED}This is not implemented yet, leaving as default${COLOR_RESET}"
fi

CURRENT_DIRS=("${DIRECTORY_NAMES_BASE[@]}")
################################################################################
################################################################################

# $1 == element
# $2 == array
function array_contains_element(){
  if [ "$#" -eq "2" ];then
    for item in "${$2[@]}"; do
        if [ "$item" = "$1" ]; then
            return true
        fi
    done
  fi
  return false
}


# $1 == "type of command"
# $2 == "name of language that failed"
# if $3 then $3 == lang, $2 == build argument
function handle_error(){
  if [ "$1" == "create" ];then
    ((create_errors++))
  elif [ "$1" == "build" ]; then
    ((build_errors++))
  elif [ "$1" == "deploy" ]; then
    ((deploy_errors++))
  fi
  errors+=("$@;")
}

# needs to have exactly 1 argument given with the path of the directory to be cleared
function clear_dir(){
  if [ $# -eq 1 ]; then
    if [ -d "$1" ]; then
        echo -n "Removing $1 directory..."
        rm -rf "$1"
        echo "deleted"
    fi
  else
    echo -e "${COLOR_RED}<clear_dir> didn't get exactly 1 argument but got $#${COLOR_RESET}"
  fi
}

function clear_files(){
  for ((i=0; i<${#DIRECTORY_NAMES_BASE[@]}; i++)); do
    dir="$ROOT_DIR/${DIRECTORY_NAMES_BASE[$i]}"
    clear_dir $dir
  done
}

function clear_cluster_by_namespace(){
  if [ "$1" == "all" ]; then
    TO_CYCLE_THROUGH=("${CURRENT_DIRS[@]}")
  else
    TO_CYCLE_THROUGH=("$@")
  fi
  echo "Clearing ALL generated namespaces"
  for arg in "${TO_CYCLE_THROUGH[@]}"; do
    ns="$arg$NAME_APENDIX"
    if [ "$(kubectl get --ignore-not-found=true ns $ns)" == "" ];then
      echo "no namespace called '$ns' found"
      continue
    fi
    # if [ "$CURRENT_BUILD_ARG" = "s2i" ] && [ array_contains_element "$arg" "$S2I_SKIP_DIRECTORIES" ]; then
    #   echo "skipping $arg because s2i"
    #   continue
    # fi
    echo -e "${COLOR_BLUE}> Clearing ns/$ns resources${COLOR_RESET}"
    kubectl delete all --all -n $ns
    kubectl wait --for=delete all --all --timeout=300s -n $ns
    echo ">> Clearing $ns ns"
    kubectl delete ns $ns
    kubectl wait --for=delete namespace/$ns --timeout=300s
  done
}

################################################################################

# create a function in current dir with arguments
function create(){
  args="$1 ns/$2"
  kubectl create ns "$2" || { echo -e "${COLOR_RED}Expected namespace/$2 to not exist${COLOR_RESET}"; handle_error "Namespace error occured"; return $SKIP_TRUE; }
  kubectl-ns "$2"
  echo "> Creating: func create $1 in ns $2"
  if func create "-l=$1"; then
    echo -e "${COLOR_GREEN}OK create $args${COLOR_RESET}"
    return $SKIP_FALSE
  fi
  echo -e "${COLOR_RED}Failed create $args${COLOR_RESET}"
  handle_error "create" "$args"
  return $SKIP_TRUE
}

# build a function in current dir with arguments
function build(){
  args="--builder=$1 $2"
  if [[ $3 -eq $SKIP_TRUE ]]; then
    echo -e "${COLOR_YELLOW}skipping build $args"
    ((build_skipped++))
    return $SKIP_TRUE
  fi
  echo ">> Building: func build $1"
  if time func build --registry=$FUNC_REGISTRY "$1"; then
    echo -e "${COLOR_GREEN}OK build $args${COLOR_RESET}"
    return $SKIP_FALSE
  fi
  echo -e "${COLOR_RED}Failed build $args${COLOR_RESET}"
  handle_error "build" "$args"
  return $SKIP_TRUE
}

#deploy a function in current dir with my registry permanently set AND given arguments
function deploy(){
  if [[ "$2" -eq $SKIP_TRUE ]]; then
    echo -e "${COLOR_YELLOW}skipping deploy $args"
    ((deploy_skipped++))
    return
  fi
  echo ">>> Deploying: func deploy"
  if time func deploy --build=false --registry=$FUNC_REGISTRY $CURRENT_DEPLOY_ARG; then
    echo -e "${COLOR_GREEN}OK deploy $1${COLOR_RESET}"
  else
    echo -e "${COLOR_RED}Failed deploy $1${COLOR_RESET}"
    handle_error "deploy" "$1"
  fi
}
################################################################################
################################################################################

if [ "$1" = "clear" ]; then
  shift
  if [ "$#" -ge 1 ]; then
    echo -e "${COLOR_YELLOW}Clearing cluster namespaces($@)${COLOR_RESET}"
    clear_cluster_by_namespace "$@"
  else
    echo -e "${COLOR_BLUE}Not clearing any cluster namespaces"
  fi
  echo -e "${COLOR_BLUE}Clearing all sub-directories generated${COLOR_RESET}"
  clear_files
  echo "done"
  return
fi

#### MAIN CYCLE ####
if [ -z "$CURRENT_DEPLOY_ARG" ];then
  echo -e "${COLOR_YELLOW}Testing build with --builder=${CURRENT_BUILD_ARG} & deploy locally for '${CURRENT_DIRS[@]}' packages${COLOR_RESET}"
elif [ "$CURRENT_DEPLOY_ARG" == "--remote" ];then
  echo -e "${COLOR_YELLOW}Testing build with --builder=${CURRENT_BUILD_ARG} & deploy remotely for '${CURRENT_DIRS[@]}' packages${COLOR_RESET}"
else
  echo -e "${COLOR_RED}Ehm, not sure what kind of deploy argument you got there chief -- '$CURRENT_DEPLOY_ARG'${COLOR_RESET}"
  exit 1
fi

ROOT_NS=$(kubectl-ns --current)
actually_ran=0

for ((i=0; i<${#CURRENT_DIRS[@]}; i++)); do
  cd "$ROOT_DIR" || { echo "cant cd to $ROOT_DIR"; exit 1; } #reset each cycle
  arg="${CURRENT_DIRS[$i]}"
  # if s2i is enabled, skip if redhat doesnt have support for the language
  if [ "$CURRENT_BUILD_ARG" = "s2i" ] && [ array_contains_element "$arg" "$S2I_SKIP_DIRECTORIES" ];then
    echo -e "${COLOR_YELLOW} skipping $arg because s2i builder is set${COLOR_RESET}"
    continue
  fi

  dir="$arg$NAME_APENDIX"
  full_path_dir="$ROOT_DIR/$dir"

  ### Delete the directory first for a new clean run
  clear_dir "$full_path_dir"
  mkdir -p "$dir"
  echo -e "${COLOR_BLUE}Working in directory $full_path_dir${COLOR_RESET}"
  cd "$full_path_dir" || { echo -e "${COLOR_RED}cant cd to $full_path_dir${COLOR_RESET}"; break; }

  ### Run func commands
  create "$arg" "$dir"
  # standard pack
  build "$CURRENT_BUILD_ARG" "$arg" "$?"
  #deploy locally
  deploy "$arg" "$?"
  echo ""
  ((actually_ran++))
done

cd $ROOT_DIR
kubectl-ns $ROOT_NS

# Print the total number of errors & skips
if [ -z $CURRENT_DEPLOY_ARG ]; then
  echo -e "${COLOR_BLUE}SUMMARY -- Ran with --builder=${CURRENT_BUILD_ARG} locally (w/o --remote)${COLOR_RESET}"
elif [  $CURRENT_DEPLOY_ARG == "--remote" ]; then
  echo -e "${COLOR_BLUE}SUMMARY -- Ran with --builder=${CURRENT_BUILD_ARG} remotely (w --remote)${COLOR_RESET}"
else
  echo -e "Ehm, not sure what kind of deploy argument you got there chief -- $CURRENT_DEPLOY_ARG"
fi


total_num_tests=$DIRECTORY_NAMES_BASE_LENGTH
if [ "$CURRENT_BUILD_ARG" == "s2i" ];then
  total_num_tests=$((total_num_tests - S2I_SKIP_DIRECTORIES_LENGTH))
fi
echo -e "Ran ${COLOR_GREEN}$actually_ran${COLOR_RESET}/$total_num_tests"
#errors
echo -e "${COLOR_RED}--- Errors ---${COLOR_RESET}"
if [ "${#errors[@]}" -gt 0 ]; then
  echo -e "${COLOR_RED}Error Descriptions: ${errors[@]}${COLOR_RESET}"
fi
if [ "$create_errors" -gt 0 ]; then
  echo "Total create errors: $create_errors"
else
  echo "No create errors!"
fi
if [ "$build_errors" -gt 0 ]; then
  echo "Total build errors: $build_errors"
else
  echo "No build errors!"
fi
if [ "$deploy_errors" -gt 0 ]; then
  echo "Total deploy errors: $deploy_errors"
else
  echo "No deploy errors!"
fi

echo -e "${COLOR_YELLOW}--- Skips ---${COLOR_RESET}"
if [ "$create_skipped" -gt 0 ]; then
  echo "Total create errors: $create_skipped"
else
  echo "No create errors!"
fi
if [ "$build_skipped" -gt 0 ]; then
  echo "Total build errors: $build_skipped"
else
  echo "No build errors!"
fi
if [ "$deploy_skipped" -gt 0 ]; then
  echo "Total deploy errors: $deploy_skipped"
else
  echo "No deploy errors!"
fi




#TODO: POSSIBLY
#run a function in current dir with arguments
#function run(){
#  echo "run: func run '$*'"
#  if func run "$1"; then
#    echo -e "${COLOR_GREEN}OK${COLOR_RESET}"
#  else
#    echo -e "${COLOR_RED}Failed${COLOR_RESET}"
#  fi
#}
#
##invoke a function in current dir
#function invoke() {
#  echo "invoke: func invoke '$*'"
#  if func invoke; then
#    echo -e "${COLOR_GREEN}OK${COLOR_RESET}"
#  else
#    echo -e "${COLOR_RED}Failed${COLOR_RESET}"
#  fi
#}