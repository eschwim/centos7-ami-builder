#!/bin/bash

REQUIRED_RPMS=(yum-plugin-fastestmirror ruby ruby-devel kpartx)
CFG_FILE=$HOME/.centos-ami-builder

## Builder functions ########################################################


build_ami() {
	get_root_device
	make_build_dirs
	make_img_file
	mount_img_file
	install_packages
	make_fstab
	setup_network
	install_grub
	enter_shell
	unmount_all
	bundle_ami
	upload_ami
	register_ami
	quit
}


# Determine what device our root partition is mounted on, and get its UUID
get_root_device() {
	read ROOT_DEV ROOT_FS_TYPE <<< $(awk '/^\/dev[^ ]+ \/ / {print $1" "$3}' /proc/mounts)
	[[ $ROOT_FS_TYPE == "xfs" ]] || fatal "Root file system on build host must be XFS (is $ROOT_FS_TYPE)"
	ROOT_UUID=$(/sbin/blkid -o value -s UUID $ROOT_DEV)
	echo "Build host root device: $ROOT_DEV, UUID: $ROOT_UUID"
}


# Create the build hierarchy.  Unmount existing paths first, if need by
make_build_dirs() {

	AMI_ROOT="$BUILD_ROOT/$AMI_NAME"
	AMI_IMG="$AMI_ROOT/$AMI_NAME.img"
	AMI_MNT="$AMI_ROOT/mnt"
	AMI_OUT="$AMI_ROOT/out"

	AMI_DEV=hda
	AMI_DEV_PATH=/dev/mapper/$AMI_DEV
	AMI_PART_PATH=${AMI_DEV_PATH}1

	output "Creating build hierarchy in $AMI_ROOT..."

	if grep -q "^[^ ]\+ $AMI_MNT" /proc/mounts; then
		yesno "$AMI_MNT is already mounted; unmount it"
		unmount_all
	fi

	mkdir -p $AMI_MNT $AMI_OUT || fatal "Unable to create create build hierarchy"

}


# Create our image file
make_img_file() {

	output "Creating image fille $AMI_IMG..."
	if [[ $AMI_TYPE == 'pv' ]]; then
		[[ -f $AMI_IMG ]] && yesno "$AMI_IMG already exists; overwrite it"
		# Create a sparse file
		dd if=/dev/zero status=none of=$AMI_IMG bs=1M count=1 seek=$AMI_SIZE || \
			fatal "Unable to create image file: $AMI_IMG"
		# Set up XFS on the sparse file
		mkfs.xfs -f $AMI_IMG  || \
			fatal "Unable create XFS file system on $AMI_IMG"
		# Clone the UUID of the builder root dev to the image file
		xfs_admin -U $ROOT_UUID $AMI_IMG  || \
			fatal "Unable to assign UUID '$ROOT_UUID' to $AMI_IMG"
	else
		if [[ -e $AMI_DEV_PATH ]]; then
			yesno "$AMI_DEV_PATH is already defined; redefine it"
			undefine_hvm_dev
		fi
		[[ -f $AMI_IMG ]] && yesno "$AMI_IMG already exists; overwrite it"

		# Create a sparse file
		rm -f $AMI_IMG && sync
		dd if=/dev/zero status=none of=$AMI_IMG bs=1M count=1 seek=$(($AMI_SIZE - 1))  || \
			fatal "Unable to create image file: $AMI_IMG"

		# Create a primary partition
		parted $AMI_IMG --script -- "unit s mklabel msdos mkpart primary 2048 100% set 1 boot on print quit" \
			 || fatal "Unable to create primary partition for $AMI_IMG"
		sync; udevadm settle

		# Set up the the image file as a loop device so we can create a dm volume for it
		LOOP_DEV=$(losetup -f)
		losetup $LOOP_DEV $AMI_IMG || fatal "Failed to bind $AMI_IMG to $LOOP_DEV."
		
		# Create a device mapper volume from our loop dev
		DM_SIZE=$(($AMI_SIZE * 2048))
		DEV_NUMS=$(cat /sys/block/$(basename $LOOP_DEV)/dev)
		dmsetup create $AMI_DEV <<< "0 $DM_SIZE linear $DEV_NUMS 0" || \
			fatal "Unable to define devicemapper volume $AMI_DEV_PATH"
		kpartx -s -a $AMI_DEV_PATH || \
			fatal "Unable to read partition table from $AMI_DEV_PATH"
		udevadm settle

		# Create our xfs partition and clone our builder root UUID onto it
		mkfs.xfs -f $AMI_PART_PATH  || \
			fatal "Unable to create XFS filesystem on $AMI_PART_PATH"
		xfs_admin -U $ROOT_UUID $AMI_PART_PATH  || \
			fatal "Unable to assign UUID '$ROOT_UUID' to $AMI_PART_PATH"
		sync
	fi
}


# Mount the image file and create and mount all of the necessary devices
mount_img_file()
{
	output "Mounting image file $AMI_IMG at $AMI_MNT..."

	if [[ $AMI_TYPE == 'pv' ]]; then
		mount -o nouuid $AMI_IMG $AMI_MNT
	else
		mount -o nouuid /dev/mapper/hda1 $AMI_MNT
	fi

	# Make our chroot directory hierarchy
	mkdir -p $AMI_MNT/{dev,etc,proc,sys,var/{cache,log,lock,lib/rpm}}

	# Create our special devices
	mknod -m 600 $AMI_MNT/dev/console c 5 1
	mknod -m 600 $AMI_MNT/dev/initctl p
	mknod -m 666 $AMI_MNT/dev/full c 1 7
	mknod -m 666 $AMI_MNT/dev/null c 1 3
	mknod -m 666 $AMI_MNT/dev/ptmx c 5 2
	mknod -m 666 $AMI_MNT/dev/random c 1 8
	mknod -m 666 $AMI_MNT/dev/tty c 5 0
	mknod -m 666 $AMI_MNT/dev/tty0 c 4 0
	mknod -m 666 $AMI_MNT/dev/urandom c 1 9
	mknod -m 666 $AMI_MNT/dev/zero c 1 5
	ln -s null $AMI_MNT/dev/X0R

	# Bind mount /dev and /proc from our builder machine
	mount -o bind /dev $AMI_MNT/dev
	mount -o bind /dev/pts $AMI_MNT/dev/pts
	mount -o bind /dev/shm $AMI_MNT/dev/shm
	mount -o bind /proc $AMI_MNT/proc
	mount -o bind /sys $AMI_MNT/sys
}


# Install packages into AMI via yum
install_packages() {

	output "Installing packages into $AMI_MNT..."
	# Create our YUM config
	YUM_CONF=$AMI_ROOT/yum.conf
	cat > $YUM_CONF <<-EOT
	[main]
	reposdir=
	plugins=0

	[base]
	name=CentOS-7 - Base
	mirrorlist=http://mirrorlist.centos.org/?release=7&arch=x86_64&repo=os
	#baseurl=http://mirror.centos.org/centos/7/os/x86_64/
	gpgcheck=1
	gpgkey=http://mirror.centos.org/centos/RPM-GPG-KEY-CentOS-7

	#released updates
	[updates]
	name=CentOS-7 - Updates
	mirrorlist=http://mirrorlist.centos.org/?release=7&arch=x86_64&repo=updates
	#baseurl=http://mirror.centos.org/centos/7/updates/x86_64/
	gpgcheck=1
	gpgkey=http://mirror.centos.org/centos/RPM-GPG-KEY-CentOS-7

	#additional packages that may be useful
	[extras]
	name=CentOS-7 - Extras
	mirrorlist=http://mirrorlist.centos.org/?release=7&arch=x86_64&repo=extras
	#baseurl=http://mirror.centos.org/centos/7/extras/x86_64/
	gpgcheck=1
	gpgkey=http://mirror.centos.org/centos/RPM-GPG-KEY-CentOS-7

	#additional packages that extend functionality of existing packages
	[centosplus]
	name=CentOS-7 - Plus
	mirrorlist=http://mirrorlist.centos.org/?release=7&arch=x86_64&repo=centosplus
	#baseurl=http://mirror.centos.org/centos/7/centosplus/x86_64/
	gpgcheck=1
	enabled=0
	gpgkey=http://mirror.centos.org/centos/RPM-GPG-KEY-CentOS-7

	#contrib - packages by Centos Users
	[contrib]
	name=CentOS-7 - Contrib
	mirrorlist=http://mirrorlist.centos.org/?release=7&arch=x86_64&repo=contrib
	#baseurl=http://mirror.centos.org/centos/7/contrib/x86_64/
	gpgcheck=1
	enabled=0
	gpgkey=http://mirror.centos.org/centos/RPM-GPG-KEY-CentOS-7

	[epel]
	name=Extra Packages for Enterprise Linux 7 - \$basearch
	#baseurl=http://download.fedoraproject.org/pub/epel/7/\$basearch
	mirrorlist=https://mirrors.fedoraproject.org/metalink?repo=epel-7&arch=\$basearch
	failovermethod=priority
	enabled=1
	gpgcheck=0
	gpgkey=http://dl.fedoraproject.org/pub/epel/RPM-GPG-KEY-EPEL-7

	[epel-debuginfo]
	name=Extra Packages for Enterprise Linux 7 - \$basearch - Debug
	#baseurl=http://download.fedoraproject.org/pub/epel/7/\$basearch/debug
	mirrorlist=https://mirrors.fedoraproject.org/metalink?repo=epel-debug-7&arch=\$basearch
	failovermethod=priority
	enabled=0
	gpgkey=http://dl.fedoraproject.org/pub/epel/RPM-GPG-KEY-EPEL-7
	gpgcheck=1

	[epel-source]
	name=Extra Packages for Enterprise Linux 7 - \$basearch - Source
	#baseurl=http://download.fedoraproject.org/pub/epel/7/SRPMS
	mirrorlist=https://mirrors.fedoraproject.org/metalink?repo=epel-source-7&arch=\$basearch
	failovermethod=priority
	enabled=0
	gpgkey=http://dl.fedoraproject.org/pub/epel/RPM-GPG-KEY-EPEL-7
	gpgcheck=1

	[elrepo]
	name=ELRepo.org Community Enterprise Linux Repository - el7
	baseurl=http://elrepo.org/linux/elrepo/el7/\$basearch/
			http://mirrors.coreix.net/elrepo/elrepo/el7/\$basearch/
			http://jur-linux.org/download/elrepo/elrepo/el7/\$basearch/
			http://repos.lax-noc.com/elrepo/elrepo/el7/\$basearch/
			http://mirror.ventraip.net.au/elrepo/elrepo/el7/\$basearch/
	mirrorlist=http://mirrors.elrepo.org/mirrors-elrepo.el7
	enabled=1
	gpgcheck=1
	gpgkey=https://www.elrepo.org/RPM-GPG-KEY-elrepo.org

	[elrepo-kernel]
	name=ELRepo.org Community Enterprise Linux Kernel Repository - el7
	baseurl=http://elrepo.org/linux/kernel/el7/\$basearch/
			http://mirrors.coreix.net/elrepo/kernel/el7/\$basearch/
			http://jur-linux.org/download/elrepo/kernel/el7/\$basearch/
			http://repos.lax-noc.com/elrepo/kernel/el7/\$basearch/
			http://mirror.ventraip.net.au/elrepo/kernel/el7/\$basearch/
	mirrorlist=http://mirrors.elrepo.org/mirrors-elrepo-kernel.el7
	enabled=1
	gpgcheck=1
	gpgkey=https://www.elrepo.org/RPM-GPG-KEY-elrepo.org
	EOT

	# Install base pacakges
	yum --config=$YUM_CONF --installroot=$AMI_MNT --quiet --assumeyes groupinstall Base
	[[ -f $AMI_MNT/bin/bash ]] || fatal "Failed to install base packages into $AMI_MNT"

	# Install additional packages that we are definitely going to want
	yum --config=$YUM_CONF --installroot=$AMI_MNT --assumeyes install \
        psmisc grub2 dhclient ntp e2fsprogs sudo elrepo-release kernel-ml \
		openssh-clients vim-minimal postfix yum-plugin-fastestmirror sysstat \
		epel-release python-setuptools gcc make xinetd rsyslog microcode_ctl \
		gnupg2 bzip2 cloud-utils-growpart cloud-init 

	# Remove unnecessary RPMS
	yum --config=$YUM_CONF --installroot=$AMI_MNT --assumeyes erase \
		plymouth plymouth-scripts plymouth-core-libs chrony

	# Enable our required services
	chroot $AMI_MNT /bin/systemctl -q enable rsyslog ntpd sshd cloud-init cloud-init-local \
		cloud-config cloud-final
	
	# Create our default bashrc files
	cat > $AMI_MNT/root/.bashrc <<-EOT
	alias rm='rm -i' cp='cp -i' mv='mv -i'		   
	[ -f /etc/bashrc ] && . /etc/bashrc					   
	EOT
	cp $AMI_MNT/root/.bashrc $AMI_MNT/root/.bash_profile

}


# Create the AMI's fstab
make_fstab() {
	output "Creating fstab..."
	if [[ $AMI_TYPE == "pv" ]]; then
		FSTAB_ROOT="UUID=$ROOT_UUID /	 xfs	defaults,noatime 1 1"
	else
		FSTAB_ROOT="/dev/sda1	   /	 xfs	defaults,noatime 1 1"
	fi

	cat > $AMI_MNT/etc/fstab <<-EOT
	$FSTAB_ROOT
	none /dev/pts devpts gid=5,mode=620 0 0
	none /proc proc defaults 0 0
	none /sys sysfs defaults 0 0
	EOT
}


# Create our eth0 ifcfg script and our SSHD config
setup_network() {
	output "Setting up network..."

	# Create our DHCP-enabled eth0 config
	cat > $AMI_MNT/etc/sysconfig/network-scripts/ifcfg-eth0 <<-EOT
	DEVICE=eth0
	BOOTPROTO=dhcp
	ONBOOT=yes
	TYPE=Ethernet
	USERCTL=yes
	PEERDNS=yes
	IPV6INIT=no
	PERSISTENT_DHCLIENT=yes
	EOT

	cat > $AMI_MNT/etc/sysconfig/network <<-EOT
	NETWORKING=yes
	NOZEROCONF=yes
	EOT

	# Amend our SSHD config
	cat >> $AMI_MNT/etc/ssh/sshd_config <<-EOT
	PasswordAuthentication no
	UseDNS no
	PermitRootLogin without-password
	EOT

	chroot $AMI_MNT chkconfig network on
}


# Create the grub config
install_grub() {
	
	AMI_BOOT_PATH=$AMI_MNT/boot
	AMI_KERNEL_VER=$(ls $AMI_BOOT_PATH | egrep -o '3\..*' | head -1)

	# Install our grub.conf for only the PV machine, as it is needed by PV-GRUB
	if [[ $AMI_TYPE == "pv" ]]; then
		output "Installing PV-GRUB config..."
		AMI_GRUB_PATH=$AMI_BOOT_PATH/grub
		mkdir -p $AMI_GRUB_PATH
		cat > $AMI_GRUB_PATH/grub.conf <<-EOT
		default=0
		timeout=0
		hiddenmenu

		title CentOS Linux ($AMI_KERNEL_VER) 7 (Core)
				root (hd0)
				kernel /boot/vmlinuz-$AMI_KERNEL_VER ro root=UUID=$ROOT_UUID console=hvc0 LANG=en_US.UTF-8 loglvl=all sync_console console_to_ring earlyprintk=xen plymouth.enable=0 net.ifnames=0 biosdevname=0
				initrd /boot/initramfs-${AMI_KERNEL_VER}.img
		EOT
		ln -sf grub.conf $AMI_GRUB_PATH/menu.lst

	# Install grub2 only for the HVM image, as the PV image uses PV-GRUB
	else
		output "Installing GRUB2..."
		cat > $AMI_MNT/etc/default/grub <<-EOT
		GRUB_TIMEOUT=1
		GRUB_DISTRIBUTOR="$(sed 's, release .*$,,g' /etc/system-release)"
		GRUB_DEFAULT=saved
		GRUB_DISABLE_SUBMENU=true
		GRUB_TERMINAL="serial console"
		GRUB_SERIAL_COMMAND="serial --speed=115200"
		GRUB_CMDLINE_LINUX="console=ttyS0,115200 console=tty0 vconsole.font=latarcyrheb-sun16 crashkernel=auto vconsole.keymap=us plymouth.enable=0 net.ifnames=0 biosdevname=0"
		GRUB_DISABLE_RECOVERY="true"
		EOT

		AMI_GRUB_PATH=$AMI_BOOT_PATH/grub2
		mkdir -p $AMI_GRUB_PATH
		echo "(hd0) $LOOP_DEV" > $AMI_GRUB_PATH/device.map
		chroot $AMI_MNT dracut --force --add-drivers "ixgbevf virtio" --kver $AMI_KERNEL_VER
		chroot $AMI_MNT grub2-install --no-floppy --modules='biosdisk part_msdos ext2 xfs configfile normal multiboot' $LOOP_DEV
		chroot $AMI_MNT grub2-mkconfig -o /boot/grub2/grub.cfg
	fi
}


# Allow user to make changes to the AMI outside of the normal build process
enter_shell() {
	output "Entering AMI chroot; customize as needed.  Enter 'exit' to finish build."
	cp /etc/resolv.conf $AMI_MNT/etc
	PS1="[${AMI_NAME}-chroot \W]# " chroot $AMI_MNT &> /dev/tty
	rm -f $AMI_MNT/{etc/resolv.conf,root/.bash_history}
}


# Unmount all of the mounted devices
unmount_all() {
	umount -ldf $AMI_MNT/{dev/pts,dev/shm,dev,proc,sys,}
	sync
	grep -q "^[^ ]\+ $AMI_MNT" /proc/mounts && \
		fatal "Failed to unmount all devices mounted under $AMI_MNT!"

	# Also undefine our hvm devices if they are currently set up with this image file
	losetup | grep -q $AMI_IMG && undefine_hvm_dev
}


# Remove the dm volume and loop dev for an HVM image file
undefine_hvm_dev() {
	kpartx -d $AMI_DEV_PATH  || fatal "Unable remove partition map for $AMI_DEV_PATH"
	sync; udevadm settle
	dmsetup remove $AMI_DEV  || fatal "Unable to remove devmapper volume for $AMI_DEV"
	sync; udevadm settle
	OLD_LOOPS=$(losetup -j $AMI_IMG | sed 's#^/dev/loop\([0-9]\+\).*#loop\1#' | paste -d' ' - -)
	[[ -n $OLD_LOOPS ]] && losetup -d $OLD_LOOPS
	losetup -D
	sleep 1; sync; udevadm settle
}


# Create an AMI bundle from our image file
bundle_ami() {
	output "Bundling AMI for upload..."
	RUBYLIB=/usr/lib/ruby/site_ruby/ ec2-bundle-image --privatekey $AWS_PRIVATE_KEY --cert $AWS_CERT \
		--user $AWS_USER --image $AMI_IMG --prefix $AMI_NAME --destination $AMI_OUT --arch x86_64 || \
		fatal "Failed to bundle image!"
	AMI_MANIFEST=$AMI_OUT/$AMI_NAME.manifest.xml
}


# Upload our bundle to our S3 bucket
upload_ami() {
	output "Uploading AMI to $AMI_S3_DIR..."
	RUBYLIB=/usr/lib/ruby/site_ruby/ ec2-upload-bundle --bucket $AMI_S3_DIR --manifest $AMI_MANIFEST \
		--access-key $AWS_ACCESS --secret-key $AWS_SECRET --retry --region $S3_REGION  || \
		fatal "Failed to upload image!"
}


# Register our uploading S3 bundle as a valid AMI
register_ami() {

	# If this is a PV image, we need to find the latest PV-GRUB kernel image
	if [[ $AMI_TYPE == "pv" ]]; then
		output "Looking up latest PV-GRUB kernel image..."
		PVGRUB_AKI=$(aws ec2 describe-images --output text --owners amazon --filters \
			Name=image-type,Values=kernel Name=name,Values='*pv-grub-hd0_*' Name=architecture,Values=x86_64 \
			| sort -r -t$'\t' -k9 | head -1 | cut -f5)
		[[ -z $PVGRUB_AKI ]] && fatal "Unable to find PV-GRUB AKI!"
		output "Found AKI $PVGRUB_AKI"

		output "Registering AMI $AMI_NAME with AWS..."
		aws ec2 register-image --image-location $AMI_S3_DIR/$AMI_NAME.manifest.xml --name $AMI_NAME --region $S3_REGION \
			--architecture x86_64 --kernel $PVGRUB_AKI --virtualization-type paravirtual  || \
			fatal "Failed to register image!"
	else
		aws ec2 register-image --image-location $AMI_S3_DIR/$AMI_NAME.manifest.xml --name $AMI_NAME --region $S3_REGION \
			--architecture x86_64 --virtualization-type hvm  || \
			fatal "Failed to register image!"
	fi
}


## Utilitiy functions #######################################################


# Print a message and exit
quit() {
	output "$1"
	exit 1
}


# Print a fatal message and exit
fatal() {
	quit "FATAL: $1"
}


# Perform our initial setup routines
do_setup() {

	source $CFG_FILE  || get_config_opts
	install_setup_rpms
	setup_aws
	sanity_check

	# Add /usr/local/bin to our path if it doesn't exist there
	[[ ":$PATH:" != *":/usr/local/bin"* ]] && export PATH=$PATH:/usr/local/bin

	output "All build requirements satisfied."
}


# Read config opts and save them to disk
get_config_opts() {

	source $CFG_FILE

	get_input "Path to local build folder (i.e. /mnt/amis)" "BUILD_ROOT"
	get_input "AMI size (in MB)" "AMI_SIZE"
	get_input "AWS User ID #" "AWS_USER"
	get_input "Path to S3 AMI storage (i.e. bucket/dir)" "S3_ROOT"
	get_input "S3 bucket region (i.e. us-west-2)" "S3_REGION"
	get_input "AWS R/W access key" "AWS_ACCESS"
	get_input "AWS R/W secret key" "AWS_SECRET"
	get_input "Path to AWS X509 key" "AWS_PRIVATE_KEY"
	get_input "Path to AWS X509 certifcate" "AWS_CERT"

	# Create our AWS config file
	mkdir -p ~/.aws
	chmod 700 ~/.aws
	cat > $HOME/.aws/config <<-EOT
	[default]
	output = json
	region = $S3_REGION
	aws_access_key_id = $AWS_ACCESS
	aws_secret_access_key = $AWS_SECRET
	EOT

	# Write our config options to a file for subsequent runs
	rm -f $CFG_FILE
	touch $CFG_FILE
	chmod 600 $CFG_FILE
	for f in BUILD_ROOT AMI_SIZE AWS_USER S3_ROOT S3_REGION AWS_ACCESS AWS_SECRET AWS_PRIVATE_KEY AWS_CERT; do
		eval echo $f=\"\$$f\" >> $CFG_FILE
	done

}


# Read a variable from the user
get_input()
{
	# Read into a placeholder variable
	ph=
	eval cv=\$${2}
	while [[ -z $ph ]]; do
		printf "%-45.45s : " "$1" &> /dev/tty
		read -e -i "$cv" ph &> /dev/tty
	done

	# Assign placeholder to passed variable name
	eval ${2}=\"$ph\"
}


# Present user with a yes/no question, quit if answer is no
yesno() {
	read -p "${1}? y/[n] " answer &> /dev/tty
	[[ $answer == "y" ]] || quit "Exiting"
}


output() {
	echo $* > /dev/tty
}


# Sanity check what we can
sanity_check() {


	# Make sure our ami size is numeric
	[[ "$AMI_SIZE" =~ ^[0-9]+$ ]] || fatal "AMI size must be an integer!"
	(( "$AMI_SIZE" >= 1000 )) || fatal "AMI size must be at least 1000 MB (currently $AMI_SIZE MB!)"

	# Check for ket/cert existance
	[[ ! -f $AWS_PRIVATE_KEY ]] && fatal "EC2 private key '$AWS_PRIVATE_KEY' doesn't exist!"
	[[ ! -f $AWS_CERT ]] && fatal "EC2 certificate '$AWS_CERT' doesn't exist!"

	# Check S3 access and file existence
	aws s3 ls s3://$S3_ROOT &> /dev/null
	[[ $? -gt 1 ]] && fatal "S3 bucket doesn't exist or isn't readable!"
	[[ -n $(aws s3 ls s3://$AMI_S3_DIR) ]] && \
		fatal "AMI S3 path ($AMI_S3_DIR) already exists;  Refusing to overwrite it"

}


# Install RPMs required by setup
install_setup_rpms() {

	RPM_LIST=/tmp/rpmlist.txt
	
	# dump rpm list to disk
	rpm -qa > $RPM_LIST
	
	# Iterate over required rpms and install missing ones
	TO_INSTALL=
	for rpm in "${REQUIRED_RPMS[@]}"; do
		if ! grep -q "${rpm}-[0-9]" $RPM_LIST; then
			TO_INSTALL="$rpm $TO_INSTALL"
		fi
	done

	if [[ -n $TO_INSTALL ]]; then
		output "Installing build requirements: $TO_INSTALL..."
		yum -y install $TO_INSTALL
	fi
}


# Set up our various EC2/S3 bits and bobs
setup_aws() {

	# ec2-ami-tools
	if [[ ! -f /usr/local/bin/ec2-bundle-image ]]; then
		output "Installing EC2 AMI tools..."
		rpm -ivh http://s3.amazonaws.com/ec2-downloads/ec2-ami-tools-1.5.6.noarch.rpm
	fi

	# PIP (needed to install aws cli)
	if [[ ! -f /bin/pip ]]; then
		output "Installing PIP..."
		easy_install pip
	fi
	if [[ ! -f /bin/aws ]]; then
		output "Installing aws-cli"
		pip install awscli
	fi

	# Set the target directory for our upload
	AMI_S3_DIR=$S3_ROOT/$AMI_NAME
}

# Main code #################################################################


# Blackhole stdout of all commands unless debug mode requested
[[ "$3" != "debug" ]] && exec &> /dev/null

case "$1" in
	reconfig)
		get_config_opts
		;;
	pv)
		AMI_NAME=${2// /_}
		AMI_TYPE=pv
		[[ -z $AMI_NAME ]] && quit "Usage: $0 pv <pv_name>"
		do_setup
		build_ami
		;;
	hvm)
		AMI_NAME=${2// /_}
		AMI_TYPE=hvm
		[[ -z $AMI_NAME ]] && quit "Usage: $0 hvm <hvm_name>"
		do_setup
		build_ami
		;;
	*)
		quit "Usage: $0 <reconfig | pv PV_NAME | hvm HVM_NAME> [debug]"
esac

# vim: tabstop=4 shiftwidth=4 expandtab
