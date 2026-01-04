#!/bin/bash
KAFKA_BIN_TOPIC="/opt/kafka/bin/kafka-topics.sh"
KAFKA_BIN_TOPIC="/opt/kafka/bin/kafka-topics.sh"
KAFKA_BROKER="localhost:9092"
TOPIC_NAME="mariadb_general_logs"
DB_NAME="my_app_db"
DB_USER="app_user"
DB_PASS="SecurePassword123"
VENV_NAME="kafka_env"
PG_VERSION="16"
#################################

# Exit on error
set -e
########
python3 -m venv $VENV_NAME
./$VENV_NAME/bin/pip install --upgrade pip
./$VENV_NAME/bin/pip install psycopg2-binary  kafka-python-ng dotenv psycopg2-binary
########
echo "Installing MariaDB and Java..."
sudo apt-get update
sudo apt-get install -y librdkafka1 rsyslog rsyslog-kafka postgresql postgresql-contrib  mariadb-server mariadb-client wget curl openjdk-11-jdk python3-pip python3.12-venv

echo "Starting MariaDB and POSTGRESQLservice..."
sudo systemctl start mariadb
sudo systemctl enable mariadb
sudo systemctl start postgresql
sudo systemctl enable postgresql

echo "Starting rsyslog service..."
systemctl restart rsyslog

echo "Creating database and user..."
sudo mysql -u root <<EOF
-- Create the database
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\`;

-- Create the user and set password
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';

-- Grant permissions
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';

-- Apply changes
FLUSH PRIVILEGES;
EOF

echo "------------------------------------------"


sudo -u postgres psql -c "CREATE DATABASE $DB_NAME;" 2>/dev/null || echo "Database $DB_NAME already exists, skipping..."
sudo -u postgres psql -c "CREATE USER $DB_USER WITH ENCRYPTED PASSWORD '$DB_PASS';" 2>/dev/null || echo "User $DB_USER already exists, skipping..."
sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE $DB_NAME TO $DB_USER;"
sudo -u postgres psql -d "$DB_NAME" -c "GRANT USAGE, CREATE ON SCHEMA public TO $DB_USER;"


cat psql.sql | sudo -u postgres psql -d "$DB_NAME"
echo "------------------------------------------"


echo "------------------------------------------"
sudo sed -i "s/#listen_addresses = 'localhost'/listen_addresses = '*'/" /etc/postgresql/$PG_VERSION/main/postgresql.conf

echo "------------------------------------------"
echo "Setup Complete!"
echo "Database: $DB_NAME"
echo "User:     $DB_USER"
echo "Password: $DB_PASS"
echo "------------------------------------------"
#########################configure log on mariadb#############################
echo "configuring log"
mkdir -p /var/log/mysql
mkdir -p /var/log/mysql
touch /var/log/mysql/general.log
touch /var/log/mysql/error.log
chown -R mysql:mysql /var/log/mysql
chmod -R 750 /var/log/mysql
cat <<EOF | sudo tee -a /etc/mysql/my.cnf

[mysqld]
# Enable General Query Logging
general_log = 1
general_log_file = /var/log/mysql/general.log

# Enable Error Logging
log_error = /var/log/mysql/error.log

# Enable Slow Query Logging (Optional)
slow_query_log = 1
slow_query_log_file = /var/log/mysql/slow.log
long_query_time = 2

# Ensure logs are written to files
log_output = FILE
EOF
echo "------------------------------------------"
echo "Restarting MariaDB..."
sudo systemctl restart mariadb
echo "Setup complete. Logs are located at /var/log/mysql/"

######################################configuring omkafka in rsyslog####################
cat <<EOF | sudo tee /etc/rsyslog.d/60-mariadb-kafka.conf
module(load="imfile")
module(load="omkafka")
input(type="imfile"
      File="/var/log/mysql/general.log"
      Tag="mariadb-query"
      Severity="info"
      Facility="local0")


template(name="KafkaTemplate" type="list") {
    constant(value="{ \"type\":\"mariadb\", \"message\":\"")
    property(name="msg" format="json" droplastlf="on")
    constant(value="\" }\n")
}

if ( $programname == 'mariadb-query') then {
    action(type="omkafka"
	   broker=["$KAFKA_BROKER"]
           topic="$TOPIC_NAME"
           template="KafkaTemplate"
           partitions.auto="on"
           resubmitOnFailure="on")
   }
EOF
# Add syslog user to the mysql group
usermod -a -G mysql syslog

# Ensure directory is accessible to the group
chmod 750 /var/log/mysql
chmod 640 /var/log/mysql/general.log

# check rsyslog service & Restart services
rsyslogd -N1 && systemctl restart rsyslog
#################################################################configuring kafka#############################################################################
echo "---------------------"
echo "configure kafka and zookeeper "
if [ -d "/opt/kafka_2.12-3.4.0/bin" ]; then
    echo "Kafka is already installed . Skipping download."
else
 wget https://archive.apache.org/dist/kafka/3.4.0/kafka_2.12-3.4.0.tgz -O /opt/kafka_2.12-3.4.0.tgz
 tar -xzf /opt/kafka_2.12-3.4.0.tgz  -C /opt
 cp -r /opt/kafka_2.12-3.4.0/ /opt/kafka/
fi
#########
cat <<EOF | sudo tee /etc/systemd/system/zookeeper.service /dev/null 2>&1
[Unit]
Description=Apache Zookeeper server
Documentation=http://zookeeper.apache.org
After=network.target

[Service]
Type=simple
User=$USER
Group=$USER
ExecStart=/opt/kafka/bin/zookeeper-server-start.sh /opt/kafka/config/zookeeper.properties
ExecStop=/opt/kafka/bin/zookeeper-server-stop.sh
Restart=on-abnormal

[Install]
WantedBy=multi-user.target
EOF
#######
cat <<EOF | sudo tee /etc/systemd/system/kafka.service /dev/null 2>&1
[Unit]
Description=Apache Kafka server
Documentation=http://kafka.apache.org/documentation.html
Requires=zookeeper.service
After=zookeeper.service

[Service]
Type=simple
User=$USER
Group=$USER
# Adjust the JAVA_HOME path if your OpenJDK 11 is in a different location
Environment="JAVA_HOME=/usr/lib/jvm/java-11-openjdk-amd64"
ExecStart=/opt/kafka/bin/kafka-server-start.sh /opt/kafka/config/server.properties
ExecStop=/opt/kafka/bin/kafka-server-stop.sh
Restart=on-abnormal

[Install]
WantedBy=multi-user.target
EOF
##############
systemctl daemon-reload
systemctl enable zookeeper
systemctl enable kafka
systemctl start zookeeper
sleep 5 
systemctl start kafka
#######################creating topic############
echo "----------------"
echo "creating topic"
$KAFKA_BIN_TOPIC --list --bootstrap-server $KAFKA_BROKER | grep -q "$TOPIC_NAME"
RESULT=$?

case $RESULT in
  0)
    echo "Topic exists. No action needed."
    ;;
  1)
    echo "Topic does not exist. Creating..."
    $KAFKA_BIN --create --topic "$TOPIC_NAME" \
               --bootstrap-server "$KAFKA_BROKER" \
               --partitions 1 \
               --replication-factor 1 

    # Insert create command here
    ;;
  *)
    echo "A serious error occurred (Kafka might be down). Exit code: $RESULT"
    exit 1
    ;;
esac
