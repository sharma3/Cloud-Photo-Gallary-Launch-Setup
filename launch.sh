#!/bin/bash

./cleanup.sh

#Declare the Array
declare -a instanceIDARR
declare -a autoscaleARNARR

#Create RDS Db instance
aws rds create-db-instance --db-instance-identifier jaysharma-rds --allocated-storage 5 --db-instance-class db.t1.micro --engine mysql --master-username JaySharma --master-user-password sharma1234 --vpc-security-group-ids sg-56ebff31 --db-subnet-group-name jaysharmadb-subnet --db-name datadb 

#db instance wait
aws rds wait db-instance-available --db-instance-identifier JaySharma-RDS
echo "db instance is created"

ENDPOINT=(`aws rds describe-db-instances --db-instance-identifier jaysharma-rds --output table | grep Address | sed -e "s/|//g" -e "s/[^ ]* //" -e "s/[^ ]* //" -e "s/[^ ]* //" -e "s/[^ ]* //"`)
echo $ENDPOINT

#Create Read Replica
aws rds create-db-instance-read-replica --db-instance-identifier jaysharma-readreplica --source-db-instance-identifier jaysharma-rds

#Launch instance
mapfile -t instanceIDARR < <(aws ec2 run-instances --image-id ami-$1 --count $2 --instance-type $3 --key-name $4 --security-group-ids $5 --subnet-id $6 --associate-public-ip-address --iam-instance-profile Name=$7 --user-data file://~/Documents/ITMO-544-A20344475-Enviornment-Setup/install-env.sh --output table | grep InstanceId | sed "s/|//g" | tr -d ' ' | sed "s/InstanceId//g")

#Calling Instance Array
echo ${instanceIDARR[@]}

#ec2 wait command
aws ec2 wait instance-running --instance-ids ${instanceIDARR[@]}
echo "Instances are Running"

#Load Balancer
ELBURL=(`aws elb create-load-balancer --load-balancer-name jaysharma-elb --listeners Protocol=HTTP,LoadBalancerPort=80,InstanceProtocol=HTTP,InstancePort=80 --subnets $6 --security-groups $5 --output=text`); echo $ELBURL
echo -e "\nFinished launching ELB and sleeping 25 seconds"
for i in {0..25}; do echo -ne '.'; sleep 1;done

#Register Instance to load balancer
aws elb register-instances-with-load-balancer --load-balancer-name jaysharma-elb --instances ${instanceIDARR[@]}

#Health Check of load balancer
aws elb configure-health-check --load-balancer-name jaysharma-elb --health-check Target=HTTP:80/index.php,Interval=30,UnhealthyThreshold=2,HealthyThreshold=2,Timeout=3
echo -e "\nWaiting an additional 180 sec - before opening the load balancer in a web browser"
for i in {0..180}; do echo -ne '.'; sleep 1;done

#Create Launch Configuration
aws autoscaling create-launch-configuration --launch-configuration-name jaysharma-lcong --image-id ami-$1 --instance-type $3 --key-name $4 --security-groups $5 --iam-instance-profile $7 --user-data file://~/Documents/ITMO-544-A20344475-Enviornment-Setup/install-env.sh

#Create Auto Scaling
mapfile -t autoscaleARNARR < <(aws autoscaling create-auto-scaling-group --auto-scaling-group-name jaysharma-autoscale --launch-configuration-name jaysharma-lcong --load-balancer-names jaysharma-elb --health-check-type ELB --min-size 1 --max-size 3 --desired-capacity 2 --default-cooldown 600 --health-check-grace-period 120 --vpc-zone-identifier $6 --output table | grep AutoScalingGroupARN | sed "s/|//g" | tr -d ' ' | sed "s/AutoScalingGroupARN//g")

echo ${autoscaleARNARR[@]}

#Create cookie stickiness policy
aws elb create-lb-cookie-stickiness-policy --load-balancer-name jaysharma-elb --policy-name my-duration-cookie-policy --cookie-expiration-period 60

#CloudWatch Alarm for SNS
 
topicArn=(`aws sns create-topic --name snsCloudWatch`)
aws sns set-topic-attributes --topic-arn $topicArn --attribute-name DisplayName --attribute-value SNS-matricWatch
aws sns subscribe --topic-arn $topicArn --protocol email --notification-endpoint $8

aws autoscaling put-notification-configuration --auto-scaling-group-name jaysharma-autoscale --topic-arn $topicArn --notification-types autoscaling:EC2_INSTANCE_LAUNCH

aws autoscaling put-notification-configuration --auto-scaling-group-name jaysharma-autoscale --topic-arn $topicArn --notification-types autoscaling:EC2_INSTANCE_TERMINATE

aws cloudwatch put-metric-alarm --alarm-name UPSNS --metric-name CPUUtilization --namespace AWS/EC2 --statistic Average --period 120 --threshold 30 --comparison-operator GreaterThanOrEqualToThreshold --evaluation-periods 1 --dimensions "Name=AutoScalingGroupName,Value=jaysharma-autoscale" --unit Percent --alarm-actions $topicArn


aws cloudwatch put-metric-alarm --alarm-name DOWNSNS --metric-name CPUUtilization --namespace AWS/EC2 --statistic Average --period 120 --threshold 10 --comparison-operator LessThanOrEqualToThreshold --evaluation-periods 1 --dimensions "Name=AutoScalingGroupName,Value=jaysharma-autoscale" --unit Percent --alarm-actions $topicArn


#CloudWatch Alarm for SNS
snsArn=(`aws sns create-topic --name $9`)
aws sns set-topic-attributes --topic-arn $snsArn --attribute-name DisplayName --attribute-value $9


#Create cloud watch for 30 threshold
SCALEUP=(`aws autoscaling put-scaling-policy --policy-name WATCHUP --auto-scaling-group-name jaysharma-autoscale --scaling-adjustment 1 --adjustment-type ChangeInCapacity`)
aws cloudwatch put-metric-alarm --alarm-name UPMATRICK --metric-name CPUUtilization --namespace AWS/EC2 --statistic Average --period 120 --threshold 30 --comparison-operator GreaterThanOrEqualToThreshold --evaluation-periods 1 --dimensions "Name=AutoScalingGroupName,Value=jaysharma-autoscale" --unit Percent --alarm-actions $SCALEUP

#Create cloud watch for 10 threshold
SCALEDOWN=(`aws autoscaling put-scaling-policy --policy-name WATCHDOWN --auto-scaling-group-name jaysharma-autoscale --scaling-adjustment -1 --adjustment-type ChangeInCapacity`)
aws cloudwatch put-metric-alarm --alarm-name DOWNMATRICK --metric-name CPUUtilization --namespace AWS/EC2 --statistic Average --period 120 --threshold 10 --comparison-operator LessThanOrEqualToThreshold  --evaluation-periods 1 --dimensions "Name=AutoScalingGroupName,Value=jaysharma-autoscale" --unit Percent --alarm-actions $SCALEDOWN

#Connect to the database and create a table
cat << EOF|mysql -h $ENDPOINT -P 3306 -u JaySharma -psharma1234 datadb
CREATE TABLE IF NOT EXISTS snstopic(snsid INT NOT NULL AUTO_INCREMENT, snsName VARCHAR(50) NOT NULL, snsArn VARCHAR(255) NOT NULL, PRIMARY KEY(snsid));
INSERT INTO snsTopic (snsName,snsArn) VALUES ('$9','$snsArn');

EOF


#Open Browser
firefox $ELBURL/index.php &
#chromium-browser $ELBURL &
export ELBURL
