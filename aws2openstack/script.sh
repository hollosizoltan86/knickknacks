#! /bin/bash

progname=`basename “$0“`
if [ $# -lt 3 ]
then
	echo "Not all necessary arguments were provided"
	echo "Usage: $progname <instance_id> <instance_region> <image_size> <os_image_name>"
	echo "Where <instance_id> is the i-1234567890abcdef value found on cloudcat"
	echo "    <instance_region> is the region the instance was created (e.g. eu-central-1)"
	echo "    <image_size> is the size in GBs of the to-be created image (checkable with du -h / --max-depth=0)"
	echo "    <os_image_name> (optional) image name on openstack, if applicable"
	exit 1;
else
	INSTANCE_ID=$1
	INSTANCE_REGION=$2
	IMAGE_SIZE=$3
	OS_IMAGE_NAME=$4
fi

if [ -z ${AWS_ACCESS_KEY_ID+x} ]; 
then 
	echo "AWS_ACCESS_KEY_ID environment variable not set, exiting"
	exit 1;
fi 

echo "Installing AWSCLI"
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
sudo ./aws/install
echo "AWSCLI install complete"
echo "_______________________"

echo "Retrieving volume information"
VOL_ID=$(aws ec2 describe-instances --instance-ids $INSTANCE_ID --region $INSTANCE_REGION --query 'Reservations[].Instances[].BlockDeviceMappings[].Ebs[].VolumeId' | grep vol | sed -e 's/^[ t]*//' -e 's/[ t]*$//' -e 's/"//g')
echo "Volume ID on source: $VOL_ID"

VOL_TYPE=$(aws ec2 describe-volumes --volume-ids $VOL_ID | grep VolumeType | sed -e 's/^[ t]*//' -e 's/[ t]*$//' -e 's/"//g' -e 's/VolumeType: //g' -e 's/,//g')
echo "Volume type of source: $VOL_TYPE"

VOL_AZ=$(aws ec2 describe-volumes --volume-ids $VOL_ID | grep AvailabilityZone | sed -e 's/^[ t]*//' -e 's/[ t]*$//' -e 's/"//g' -e 's/AvailabilityZone: //g' -e 's/,//g')
echo "Volume AZ of source: $VOL_AZ"
echo "_______________________"

echo "Creating secondary volume"
NEW_VOL=$(aws ec2 create-volume --size $IMAGE_SIZE --region $INSTANCE_REGION --availability-zone $VOL_AZ --volume-type $VOL_TYPE | grep VolumeId | sed -e 's/^[t]*//' -e 's/[t]*$//' -e 's/"//g' -e 's/VolumeId: //g' -e 's/,//g')
echo "Volume ID of secondary volume: $NEW_VOL"
echo "Waiting a minute for volume creation"
sleep 60
echo "_______________________"

echo "Attaching volume to instance"
aws ec2 attach-volume --volume-id $NEW_VOL --instance-id $INSTANCE_ID --device /dev/xvdf
echo "Waiting for attach-volume completion (2 mins)"
sleep 60
echo "Waiting for attach-volume completion (1 min)"
sleep 60
echo "Volume attached"
echo "_______________________"

echo "Partitioning new disk"
(echo n; echo p; echo 1; echo “”; echo “”; echo w) | sudo fdisk /dev/xvdf
mkfs.ext4 /dev/xvdf1; mkdir /tmp/disk; mount /dev/xvdf1 /tmp/disk
echo "Done"
echo "_______________________"

echo "Removing AWSCLI (temporarily)"
rm -f $(which aws)
rm -f $(which aws_completer)
rm -rf ./aws
rm -rf ./awscliv2.zip
rm -rf /usr/local/aws-cli/
echo "Remove complete"
echo "_______________________"

echo "Syncing FS to new volume"
rsync -avxHAX / /tmp/disk >/dev/null
echo "Done"
echo "_______________________"

echo "Creating image file from the volume"
dd if=/dev/xvda1 of=/tmp/disk/disk.img
cp /tmp/disk/disk.img /disk.img
echo "_______________________"

echo "Re-Installing AWSCLI"
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
sudo ./aws/install
echo "AWSCLI re-install complete"
echo "_______________________"

echo "Cleaning up"
umount /tmp/disk
aws ec2 detach-volume --volume-id $NEW_VOL --region $INSTANCE_REGION
echo "Waiting for detach-volume completion (1 min)"
sleep 60
aws ec2 delete-volume --volume-id $NEW_VOL --region $INSTANCE_REGION
echo "New volume detached and deleted"

echo "Checking openstack credentials"
if [ -z ${OS_PROJECT_NAME+x} ]; then echo "OS_PROJECT_NAME environment variable not set, skipping Openstack installation"; 
else 
	echo "Installing openstack client"; 
	yes | yum install python3
	yes | yum install python-devel python-pip
	python3 -m pip install --upgrade pip
	python3 -m pip install python-openstackclient;
	openstack image create --container-format bare --disk-format raw --file /disk.img --progress $OS_IMAGE_NAME
fi
echo "_______________________"

