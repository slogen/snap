#!/bin/bash
#set -x

### variables for the LVM paths and names
lvm_vg="/dev/h0r5"
lvm_name="host0.libvirt"
lvm_src="${lvm_vg}/${lvm_name}"
lvm_snap_name="${lvm_name}.rsnap"
lvm_snap="${lvm_vg}/${lvm_snap_name}"

mount_dir="/mnt/$lvm_snap_name"
lock_file="$mount_dir.lock"

lastarg="${!#}"

# track libvirtd domains that we have suspended in ${suspended_domains[@]}
declare -a suspended_domains

# All functions are written to carefully succeed and exit 0 or exit
# non-0 and cause aborting processing and rolling back

### helper functions for suspending and getting ready to backup

create_snapshot() { 
    lvcreate -L 100G -n "$lvm_snap_name" -s "$lvm_src" 1>&2
    #2>&1 \
    #  | grep -v "leaked on lv" \
    #  | grep -v "/dev/nbd" \
    #  | grep -v "created" \
    #	1>&2
}

mount_mount_dir() { 
    test -d "$mount_dir" || mkdir -p "$mount_dir"
    mount -o ro,noexec,nosuid --bind "$lvm_snap" "$mount_dir"
}
suspend_domains() {
    local domains=($(virsh -r -q list | grep 'running' | awk '{print $2;}'))
    for domain in "${domains[@]}"; do
	virsh suspend "$domain" 1>/dev/null || return 1
	suspended_domains[${#suspended_domains[@]}]="$domain"
    done
}

### helper function for cleaning up
umount_mount_dir() {
    findmnt --target "$mount_dir" >/dev/null 2>&1 && \
	{ umount "${mount_dir}" >/dev/null \
	  || umount -f "${mount_dir}" >/dev/null; }
}
delete_snapshot() { 
    { 
	lvdisplay "$lvm_snap" >/dev/null && \
	lvremove -f "$lvm_snap" >/dev/null; \
    } 2>&1 | grep -v "leaked on lv" \
	    | grep -v "One or more specified logical volume" \
    1>&2
}
resume_domains() {
    local domain
    for domain in "${suspended_domains[@]}"; do
	virsh resume "$domain" 1>/dev/null
	suspended_domains=(${suspended_domains[@]/"$domain"/})
    done
}
completed() {
    # main cleanup-function. tries hard to unroll effects
    # so this function is registered with "trap" INT TERM EXIT
    local errcode="${1:-255}"
    local lockpid=""
    if test -f "${lock_file}"; then
	lockpid=$(< "$lock_file")
	if test "x$lockpid" == "x$$"; then
	    umount_mount_dir || :
	    delete_snapshot || :
	    resume_domains || :
	    rm "${lock_file}" || :
	fi
    fi
    trap - INT TERM EXIT
    exit "$errcode"
}

### helper functions for making the actual backup
## --no-whole-file prevents copying entire file!
rsync_content() {
    #local mount_dir="/tmp/tst2"
    echo "rsync: $@" 1>&2
    nice ionice -c 3 rsync ${@/$lastarg/$mount_dir/}
}

create_snapshot_and_resume() {
    # helper function that 
    # 1. snapshots
    # 2. always resumes
    # 3. returns whether snapshot was a success (not the resumes)
    echo "--- create_snapshot $(date --rfc-3339=seconds)" 1>&2
    create_snapshot
    local ok="$?"
    echo "--- resume_domains $(date --rfc-3339=seconds)" 1>&2
    resume_domains
    echo "--- back $(date --rfc-3339=seconds)" 1>&2
    return "$ok"
}

#### HACK No snapshot
#create_snapshot_and_resume() {
#    resume_domains
#    return 0
#}
#mount_mount_dir() {
#    test -d "$mount_dir" || mkdir -p "$mount_dir"
#    mount -o ro,noexec,nosuid --bind /var/lib/libvirt "$mount_dir" \
#	2>&1 \
#	  | grep -v "seems to be mounted read-write" \
#	1>&2
#    local ok="$?"
#    if test "x$ok" = "x1"; then
#	ok=0
#    fi
#    return "$ok"
#}
#rsync_content() { echo "HACK rsync_content" 1>&2; }
#####################

act() {
    suspend_domains \
	&& create_snapshot_and_resume \
	&& mount_mount_dir \
	&& rsync_content "$@"
    
    ok="$?"
    return "$ok"
}
work() {
    # Remember to cleanup!
    trap "completed" INT TERM EXIT
    act "$@"
    local ok="$?"
    completed "$ok"
}

# Atomic check for ${lock-file}
if ( set -o noclobber; \
	[ -f "${lock_file}" ] \
        && ! kill -0 $(< "${lock_file}") ; 2>/dev/null \
        && rm -- "${lock_file}"; \
	echo "$$" > "${lock_file}") 2> /dev/null; then
    work "$@"
    ok="$?"
    exit "$ok"
else
    echo "Another backup is already active!" 1>&2
fi
