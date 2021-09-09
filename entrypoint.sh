#!/bin/sh
set -e

: "INPUT_DEBUG: ${INPUT_DEBUG:=false}"
! "${INPUT_DEBUG}" || set -x

##
# Global Config
: "INPUT_HOST: ${INPUT_HOST:=localstack}"
: "INPUT_PORT: ${INPUT_PORT:=4566}"
: "INPUT_REGION: ${INPUT_REGION:=us-east-1}"
: "INPUT_SERVICES: ${INPUT_SERVICES:=ec2 iam sts cloudwatch cloudwatchevents}"
: "INPUT_TIMEOUT: ${INPUT_TIMEOUT:=20}"
: "INPUT_LOG_ONLY: ${INPUT_LOG_ONLY:=false}"
: "WORKDIR: ${WORKDIR:=${PWD}}"
: "GITHUB_ENV: ${GITHUB_ENV:=/dev/null}"
AWS_ENDPOINT_URL="http://${INPUT_HOST}:${INPUT_PORT}"
export AWS_DEFAULT_REGION="${INPUT_REGION}"
echo "::set-output name=endpoint_url::${AWS_ENDPOINT_URL}"

##
# Helper Functions
error() { : "error($@)" ; echo "error: $*" >&2 ; }
die() { : "die($@)" ; error "$*" ; exit 1 ; }
upper() { printf '%s' "${*}" | tr '[a-z]' '[A-Z]'; }
lower() { printf '%s' "${*}" | tr '[A-Z]' '[a-z]'; }
title() {
	while test "$#" -gt '0'; do
		printf '%s' "$(upper "$(printf '%c' "${1}")")${1#?}"
		shift
	done
}
aws() { command aws --output=json --endpoint-url "${AWS_ENDPOINT_URL}" "$@"; }
localstack_id() { docker ps -q -a --no-trunc --format 'table {{.ID}} {{.Image}}' | awk '/localstack/{print$1}'; }
net2ip() {
	printf '%d.%d.%d.%d' \
		"$(( ${1} >> 24 & 255 ))" \
		"$(( ${1} >> 16 & 255 ))" \
		"$(( ${1} >> 8 & 255 ))" \
		"$(( ${1} >> 0 & 255 ))"
}
ip2net() {
	set -- $(echo "${*%/*}" | tr '.' ' ')
	echo $(( $(( ${1} << 24 )) + $(( ${2} << 16 )) + $(( ${3} << 8 )) + ${4} ))
}
timeout() {
	test "${1}" = '__TIMEOUT__' || return
	shift
	docker logs "$(localstack_id)"
	die "$*"
}

##
# Check our dependencies
aws --version > /dev/null 2>&1 || die 'awscli not found'
docker --version > /dev/null 2>&1 || die 'docker not found'
cd "${WORKDIR}"

if "${INPUT_LOG_ONLY}"; then
	docker logs "$(localstack_id)"
	exit 0
fi


##
# Wait for Localstack to finish startup
printf 'Looking for localstack ...'
while for attempt in $(seq "${INPUT_TIMEOUT}") __TIMEOUT__; do
	timeout "${attempt}" 'localsack not running'
	test -z "$(localstack_id)" || break 2
	sleep 5
	printf '.'
done ; do unset attempt ; done
echo ' found'

printf 'Waiting for localstack to be ready ...'
while for attempt in $(seq "${INPUT_TIMEOUT}") __TIMEOUT__; do
	timeout "${attempt}" 'localsack not ready'
	! docker logs "$(localstack_id)" | grep -q '^Ready' || break 2
	sleep 5
	printf '.'
done ; do unset attempt ; done
curl --no-progress-meter "${AWS_ENDPOINT_URL}/health" || :

##
# Clean-out the default VPC
printf 'Cleaning up VPC ...'
for subnet_id in $(aws ec2 describe-subnets | jq -rc '.Subnets[].SubnetId'); do
	test "${subnet_id}" != 'null' || break
	aws ec2 delete-subnet --subnet-id "${subnet_id}"
	printf '.'
done
unset subnet_id
resp="$(aws ec2 describe-vpcs --filters 'Name=isDefault,Values=true')"
vpc_id="$(echo "${resp}" | jq -rc '.Vpcs[].VpcId')"
netaddr="$(ip2net "$(echo "${resp}" | jq -rc '.Vpcs[].CidrBlock')")"
for assoc_id in $(echo "${resp}"|jq -rc '.Vpcs[].CidrBlockAssociationSet[].AssociationId'); do
	aws ec2 disassociate-vpc-cidr-block --association-id "${assoc_id}" >/dev/null 2>&1 || :
	printf '.'
done
echo ' done'
echo "::set-output name=vpc_id::${vpc_id}"

##
# Based on Amazon's quickstart recomendations.
# See: <https://docs.aws.amazon.com/quickstart/latest/vpc/images/quickstart-vpc-design-fullscreen.png>
# Note: we do not create the spare/dedicated subnets here as we do not use them
# and create-default-subnet breaks on localstack
for subnet in private/19 public/20; do
	subnets=
	printf 'Creating %s subnets ...' "${subnet%/*}"
	az_count='0'
	for az in $(aws ec2 describe-availability-zones | jq -rc .AvailabilityZones[].ZoneName); do
		cidr_block="$(net2ip "${netaddr}")/${subnet#*/}"

		case "${subnet%/*}" in
		(default)
			resp="$(aws ec2 create-default-subnet \
				--availability-zone "${az}")";;
		(*)
			resp="$(aws ec2 create-subnet \
				--vpc-id "${vpc_id}" \
				--availability-zone "${az}" \
				--cidr-block "${cidr_block}")";;
		esac

		##
		# Wait for the subnet to finish creating
		subnet_id="$(echo "${resp}"|jq -rc '.Subnet.SubnetId')"
		while state="$(aws ec2 describe-subnets --subnet-id "${subnet_id}" | jq -rc '.Subnets[].State')"
		do test "${state}" != 'available' || break; done
		unset state

		public='--map-public-ip-on-launch'
		test "${subnet%/*}" = 'public' || public='--no-map-public-ip-on-launch'
		resp="$(aws ec2 modify-subnet-attribute --subnet-id "${subnet_id}" "${public}")"
		unset public

		subnets="${subnets#,},${subnet_id}"
		netaddr="$(( ${netaddr} + ( 2 << (32 - (${subnet#*/} + 1) ) ) ))"
		unset cidr_block
		printf '.'
		az_count="$((${az_count} + 1))"
		test "${az_count}" -lt '3' || break
	done
	echo ' done'
	unset az

	echo "::set-output name=${subnet%/*}_subnets::${subnets}"
done
unset subnets

security_group_ids=
printf 'Cleaning up existing security groups ...'
resp="$(aws ec2 describe-security-groups)"
count="$(echo "${resp}" | jq -rc '.SecurityGroups | length')"
for index in $(seq $((${count} - 1))); do
	sg_name="$(echo "${resp}" | jq -rc ".SecurityGroups[${index}].GroupName")"
	sg_id="$(echo "${resp}" | jq -rc ".SecurityGroups[${index}].GroupId")"
	test "${sg_name}" != 'default' || continue
	aws ec2 delete-security-group --group-id "${sg_id}"
	printf '.'
done
echo ' done'

for dir in egress ingress; do
	printf 'Creating %s Security Groups ...' "$(title "${dir}")"
	resp="$(aws ec2 create-security-group --description "Testing $(title "${dir}")" --group-name "${dir}-allow-all" --vpc-id "${vpc_id}")"
	sg_id="$(echo "${resp}" | jq -rc '.GroupId')"
	security_group_ids="${security_group_ids#,},${sg_id}"
	#resp="$(aws ec2 authorize-security-group-${dir} --group-id "${sg_id}" --protocol 'all' --port '0-65535' --cidr '0.0.0.0/0')"
	echo ' done'
done
echo "::set-output name=security_group_ids::${security_group_ids}"

printf 'Create default ECS cluster ...'
resp="$(aws ecs create-cluster --cluster-name default)"
echo ' done'
cluster_name="$(echo "${resp}"| jq -rc '.cluster.clusterName')"
cluster_arn="$(echo "${resp}"| jq -rc '.cluster.clusterArn')"
cluster_id="${cluster_arn}"
echo "::set-output name=cluster_name::${cluster_name}"
echo "::set-output name=cluster_id::${cluster_id}"
echo "::set-output name=cluster_arn::${cluster_arn}"
