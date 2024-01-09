#!/bin/bash
set -euo pipefail

# see https://github.com/siderolabs/talos/releases
TALOS_VERSION="1.6.1"

# see https://github.com/siderolabs/extensions/pkgs/container/qemu-guest-agent
QEMU_GUEST_AGENT_VERSION="8.1.3"

export CHECKPOINT_DISABLE='1'

# One of TRACE, DEBUG, INFO, WARN or ERROR.
export TF_LOG='DEBUG'
export TF_LOG_PATH='terraform.log'

export TALOSCONFIG="$PWD/talosconfig.yml"
export KUBECONFIG="$PWD/kubeconfig.yml"

function in-group {
    local group

    group="${1}"

    id -nGz "${USERNAME}" \
        | tr '\0' '\n' \
        | grep -E "^${group}\$" >/dev/null
}

function container {
    if command -v docker >/dev/null; then
        if in-group docker; then
            docker "${@}"
        else
            sudo docker "${@}"
        fi
    elif command -v podman >/dev/null; then
        sudo podman "${@}"
    fi
}

function virsh {
    /bin/virsh --connect 'qemu:///system' "${@}"
}


function nodes {
    terraform output -raw controllers
    echo -n ","
    terraform output -raw workers
}


function step {
    echo "### $* ###"
}

function build-image {
    local version_tag volume

    # see https://www.talos.dev/v1.6/talos-guides/install/boot-assets/
    # see https://www.talos.dev/v1.6/advanced/metal-network-configuration/
    # see Profile type at
    # https://github.com/siderolabs/talos/blob/v1.6.1/pkg/imager/profile/profile.go#L20-L41
    version_tag="v${TALOS_VERSION}" #
    volume="talos-${TALOS_VERSION}.qcow2"

    rm -rf tmp/talos
    mkdir -p tmp/talos

    cat > "tmp/talos/talos-${TALOS_VERSION}.yml" <<EOF
arch: amd64
platform: nocloud
secureboot: false
version: ${version_tag}
customization:
  extraKernelArgs:
    - net.ifnames=0
input:
  kernel:
    path: /usr/install/amd64/vmlinuz
  initramfs:
    path: /usr/install/amd64/initramfs.xz
  baseInstaller:
    imageRef: ghcr.io/siderolabs/installer:${version_tag}
  systemExtensions:
    - imageRef: ghcr.io/siderolabs/qemu-guest-agent:$QEMU_GUEST_AGENT_VERSION
output:
  kind: image
  imageOptions:
    diskSize: $((2*1024*1024*1024))
    diskFormat: raw
  outFormat: raw
EOF
    container run --rm -i                                                      \
              -v "${PWD}/tmp/talos:/secureboot:ro"                             \
              -v "${PWD}/tmp/talos:/out"                                       \
              -v "/dev:/dev"                                                   \
              --privileged                                                     \
              "ghcr.io/siderolabs/imager:${version_tag}"                       \
              - <<<"$(cat tmp/talos/talos-${TALOS_VERSION}.yml)"

    qemu-img convert -O qcow2                                                  \
             "tmp/talos/nocloud-amd64.raw"                                     \
             "tmp/talos/${volume}"
    qemu-img info "tmp/talos/${volume}"

    virsh vol-delete    --pool default "${volume}" 2>/dev/null || true
    virsh vol-create-as --pool default "${volume}" 10M
    virsh vol-upload    --pool default "${volume}" "tmp/talos/${volume}"

    cat >terraform.tfvars <<EOF
talos_version                  = "$TALOS_VERSION"
talos_libvirt_base_volume_name = "$volume"
EOF
}

function init {
  step 'build talos image'
  build-image
  step 'terraform init'
  terraform init -lockfile=readonly
}

function plan {
  step 'terraform plan'
  terraform plan -out=tfplan
}

function apply {
  step 'terraform apply'
  terraform apply ./tfplan
  terraform output -raw talosconfig >talosconfig.yml
  terraform output -raw kubeconfig >kubeconfig.yml
  health
}

function plan-apply {
    plan
    apply
}

function health {
    local controllers workers controller

    step 'talosctl health'

    controllers="$(terraform output -raw controllers)"
    workers="$(terraform output -raw workers)"
    controller="$(echo "${controllers}" | cut -d , -f 1)"

    talosctl -e "${controller}" -n "${controller}"                             \
             health                                                            \
             --control-plane-nodes "${controllers}"                            \
             --worker-nodes "${workers}"

    info
}

function info {
    local nodes query

    mapfile -d ',' -t nodes < <(nodes)
    query='select(.metadata.id | test("v\\d+")) | .spec.machine.install.image'

    step 'talos node installer image'
    for node in "${nodes[@]}"; do
        # NB there can be multiple machineconfigs in a machine. we only want to
        #    see the ones with an id that looks like a version tag.
        talosctl -n "${node}" get machineconfigs -o json                       \
            | jq -r "${query}"                                                 \
            | sed -E "s,(.+),$node: \1,g"
    done

    step 'talos node os-release'
    for node in "${nodes[@]}"; do
        talosctl -n "${node}" read /etc/os-release \
            | sed -E "s,(.+),${node}: \1,g"
    done
}

function upgrade {
    local nodes

    mapfile -d ',' -t nodes < <(nodes)

    step 'talosctl upgrade'
    for node in "${nodes[@]}" ; do
        talosctl -e "${node}" -n "${node}" upgrade --preserve --wait
    done

    health
}

function destroy {
  terraform destroy -auto-approve
}

function usage {
    local cmds
    cmds="apply|destroy|health|info|init|plan|plan-apply|upgrade"
    echo "Usage: $(basename "${0}") <${cmds}>"
}

function main {
    local cmds

    if [ ! "${#}" = 1 ]; then
        usage
        exit 1
    fi

    case "${1}" in
        apply)      apply      ;;
        destroy)    destroy    ;;
        health)     health     ;;
        info)       info       ;;
        init)       init       ;;
        plan)       plan       ;;
        plan-apply) plan-apply ;;
        upgrade)    upgrade    ;;
        *)
            usage
            exit 1
            ;;
    esac
}

main "${@}"; exit
