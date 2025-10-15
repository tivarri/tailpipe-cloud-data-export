#!/bin/bash

# Prompt user for start-time and end-time
read -p "Enter start time (yyyy-mm-dd): " START_DATE
read -p "Enter end time (yyyy-mm-dd): " END_DATE

# Convert to required format (yyyy-mm-ddThh:mm:ssZ)
START_TIME="${START_DATE}T00:00:00Z"
END_TIME="${END_DATE}T23:59:59Z"

# The rest of the script remains unchanged

# Output CSV file
OUTPUT_FILE="ec2_instance_history_december_2024.csv"
TEMP_LAUNCH_FILE="temp_launch.csv"
TEMP_TERMINATE_FILE="temp_terminate.csv"
TEMP_RUNNING_FILE="temp_running.csv"

# Detect OS (macOS or Linux)
OS_TYPE=$(uname)

# Use gdate for macOS, date for Linux
if [[ "$OS_TYPE" == "Darwin" ]]; then
    DATE_CMD="gdate"
else
    DATE_CMD="date"
fi

# Write CSV header
echo "Region,InstanceID,InstanceType,LaunchTime,TerminationTime" > "$OUTPUT_FILE"

# Initialize temp files
echo "Region,InstanceID,InstanceType,LaunchTime" > "$TEMP_LAUNCH_FILE"
echo "Region,InstanceID,TerminationTime" > "$TEMP_TERMINATE_FILE"
echo "Region,InstanceID,InstanceType,LaunchTime" > "$TEMP_RUNNING_FILE"

# Fetch AWS regions
AWS_REGIONS=$(aws ec2 describe-regions --query "Regions[].RegionName" --output text)

if [[ -z "$AWS_REGIONS" ]]; then
    echo "❌ ERROR: No AWS regions found. Check AWS credentials!"
    exit 1
fi

# Fetch instance data
for region in $AWS_REGIONS; do
    echo "📡 Fetching instance data for region: $region"

    # Instances launched
    aws cloudtrail lookup-events --region "$region" \
        --lookup-attributes AttributeKey=EventName,AttributeValue=RunInstances \
        --start-time 2024-12-01T00:00:00Z --end-time 2024-12-31T23:59:59Z \
        --query "Events" --output json | jq -r --arg region "$region" '
        .[] | select(.CloudTrailEvent | fromjson? | .responseElements.instancesSet.items[0].instanceId != null) |
        (.CloudTrailEvent | fromjson) | 
        [$region, .responseElements.instancesSet.items[0].instanceId, .responseElements.instancesSet.items[0].instanceType, .eventTime] | @csv
    ' >> "$TEMP_LAUNCH_FILE"

    # Instances terminated
    aws cloudtrail lookup-events --region "$region" \
        --lookup-attributes AttributeKey=EventName,AttributeValue=TerminateInstances \
        --start-time 2024-12-01T00:00:00Z --end-time 2024-12-31T23:59:59Z \
        --query "Events" --output json | jq -r --arg region "$region" '
        .[] | select(.CloudTrailEvent | fromjson? | .responseElements.instancesSet.items[0].instanceId != null) |
        (.CloudTrailEvent | fromjson) | 
        [$region, .responseElements.instancesSet.items[0].instanceId, .eventTime] | @csv
    ' >> "$TEMP_TERMINATE_FILE"

    # Instances that were running before December and are still running
    aws ec2 describe-instances --region "$region" \
        --filters "Name=instance-state-name,Values=running" \
        --query "Reservations[].Instances[]" --output json | jq -r --arg region "$region" '
        map(
            select(.LaunchTime < "2024-12-01T00:00:00Z") | 
            [$region, .InstanceId, .InstanceType, .LaunchTime]
        ) | .[] | @csv
    ' >> "$TEMP_RUNNING_FILE"
done

# Merge launch and termination data
awk -F',' 'NR==FNR {t[$2]=$3; next} {print $1 "," $2 "," $3 "," $4 "," t[$2]}' "$TEMP_TERMINATE_FILE" "$TEMP_LAUNCH_FILE" > temp_merged.csv

# Append "still running" instances to the output with "Still Running" as termination time
awk -F',' '{print $1 "," $2 "," $3 "," $4 ",Still Running"}' "$TEMP_RUNNING_FILE" >> temp_merged.csv

# Final output
mv temp_merged.csv "$OUTPUT_FILE"

# Cleanup temp files
rm -f "$TEMP_LAUNCH_FILE" "$TEMP_TERMINATE_FILE" "$TEMP_RUNNING_FILE"

echo "✅ Data extraction complete. Output saved to $OUTPUT_FILE"