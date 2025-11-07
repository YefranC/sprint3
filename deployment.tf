# ******************************************************************
# ****** Infraestructura para ASR de Disponibilidad (Provesi) ******
# ******************************************************************
#
# Elementos a desplegar en AWS:
# 1. Grupos de seguridad:
#    - cbd-traffic-django (puerto 8080)
#    - cbd-traffic-cb (puertos 8000 y 8001)
#    - cbd-traffic-db (puerto 5432)
#    - cbd-traffic-ssh (puerto 22)
#
# 2. Instancias EC2:
#    - cbd-kong (El componente de "Alerta")
#    - provesi-db-a (Base de datos A)
#    - provesi-db-b (Base de datos B - Redundancia)
#    - provesi-servidor (El Servidor Django)
# ******************************************************************

variable "region" {
  description = "AWS region for deployment"
  type        = string
  default     = "us-east-1"
}

variable "project_prefix" {
  description = "Prefix used for naming AWS resources"
  type        = string
  default     = "cbd"
}

variable "instance_type" {
  description = "EC2 instance type for application hosts"
  type        = string
  default     = "t2.nano"
}

provider "aws" {
  region = var.region
}

locals {
  project_name = "Provesi-ASR-Disponibilidad"
  repository   = "https://github.com/ISIS2503/ISIS2503-MonitoringApp.git"
  branch       = "Circuit-Breaker"

  common_tags = {
    Project   = local.project_name
    ManagedBy = "Terraform"
  }
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# --- GRUPOS DE SEGURIDAD ---

resource "aws_security_group" "traffic_django" {
  name        = "${var.project_prefix}-traffic-django"
  description = "Allow application traffic on port 8080"
  ingress {
    description = "HTTP access for service layer"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = merge(local.common_tags, { Name = "${var.project_prefix}-traffic-services" })
}

resource "aws_security_group" "traffic_cb" {
  name        = "${var.project_prefix}-traffic-cb"
  description = "Expose Kong circuit breaker ports"
  ingress {
    description = "Kong traffic"
    from_port   = 8000
    to_port     = 8001
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = merge(local.common_tags, { Name = "${var.project_prefix}-traffic-cb" })
}

resource "aws_security_group" "traffic_db" {
  name        = "${var.project_prefix}-traffic-db"
  description = "Allow PostgreSQL access"
  ingress {
    description = "Traffic from anywhere to DB (Como en el original)"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = merge(local.common_tags, { Name = "${var.project_prefix}-traffic-db" })
}

resource "aws_security_group" "traffic_ssh" {
  name        = "${var.project_prefix}-traffic-ssh"
  description = "Allow SSH access"
  ingress {
    description = "SSH access from anywhere"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = merge(local.common_tags, { Name = "${var.project_prefix}-traffic-ssh" })
}

# --- INSTANCIAS EC2 ---

# Recurso. Define la instancia EC2 para Kong (Circuit Breaker / Alerta).
resource "aws_instance" "kong" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.instance_type
  associate_public_ip_address = true
  vpc_security_group_ids      = [aws_security_group.traffic_cb.id, aws_security_group.traffic_ssh.id]

  tags = merge(local.common_tags, {
    Name = "${var.project_prefix}-kong"
    Role = "circuit-breaker"
  })
}

# Recurso. Define la instancia EC2 para la base de datos PostgreSQL (Instancia A).
resource "aws_instance" "provesi_db_a" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.instance_type
  associate_public_ip_address = true
  vpc_security_group_ids      = [aws_security_group.traffic_db.id, aws_security_group.traffic_ssh.id]
  user_data                   = <<-EOT
    #!/bin/bash
    sudo apt-get update -y
    sudo apt-get install -y postgresql postgresql-contrib
    sudo -u postgres psql -c "CREATE USER monitoring_user WITH PASSWORD 'isis2503';"
    sudo -u postgres createdb -O monitoring_user monitoring_db
    echo "host all all 0.0.0.0/0 trust" | sudo tee -a /etc/postgresql/16/main/pg_hba.conf
    echo "listen_addresses='*'" | sudo tee -a /etc/postgresql/16/main/postgresql.conf
    echo "max_connections=2000" | sudo tee -a /etc/postgresql/16/main/postgresql.conf
    sudo service postgresql restart
    EOT
  tags = merge(local.common_tags, {
    Name = "provesi-db-a"
    Role = "database"
  })
}

# Recurso. Define la instancia EC2 para la base de datos PostgreSQL (Instancia B).
resource "aws_instance" "provesi_db_b" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.instance_type
  associate_public_ip_address = true
  vpc_security_group_ids      = [aws_security_group.traffic_db.id, aws_security_group.traffic_ssh.id]
  user_data                   = <<-EOT
    #!/bin/bash
    sudo apt-get update -y
    sudo apt-get install -y postgresql postgresql-contrib
    sudo -u postgres psql -c "CREATE USER monitoring_user WITH PASSWORD 'isis2503';"
    sudo -u postgres createdb -O monitoring_user monitoring_db
    echo "host all all 0.0.0.0/0 trust" | sudo tee -a /etc/postgresql/16/main/pg_hba.conf
    echo "listen_addresses='*'" | sudo tee -a /etc/postgresql/16/main/postgresql.conf
    echo "max_connections=2000" | sudo tee -a /etc/postgresql/16/main/postgresql.conf
    sudo service postgresql restart
    EOT
  tags = merge(local.common_tags, {
    Name = "provesi-db-b"
    Role = "database"
  })
}

# Recurso. Define la instancia EC2 para la aplicación "Provesi" (Django).
resource "aws_instance" "provesi_servidor" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.instance_type
  associate_public_ip_address = true
  vpc_security_group_ids      = [aws_security_group.traffic_django.id, aws_security_group.traffic_ssh.id]
  user_data                   = <<-EOT
    #!/bin/bash
    # Apunta a la Base de Datos A para la configuración inicial
    sudo export DATABASE_HOST=${aws_instance.provesi_db_a.private_ip}
    echo "DATABASE_HOST=${aws_instance.provesi_db_a.private_ip}" | sudo tee -a /etc/environment
    sudo apt-get update -y
    sudo apt-get install -y python3-pip git build-essential libpq-dev python3-dev
    mkdir -p /labs
    cd /labs
    if [ ! -d ISIS2503-MonitoringApp ]; then
      git clone ${local.repository}
    fi
    cd ISIS2503-MonitoringApp
    git fetch origin ${local.branch}
    git checkout ${local.branch}
    sudo pip3 install --upgrade pip --break-system-packages
    sudo pip3 install -r requirements.txt --break-system-packages
    sudo python3 manage.py makemigrations
    sudo python3 manage.py migrate
    EOT
  tags = merge(local.common_tags, {
    Name = "provesi-servidor"
    Role = "application-server"
  })
  # Depende de AMBAS bases de datos
  depends_on = [aws_instance.provesi_db_a, aws_instance.provesi_db_b]
}

# --- SALIDAS (OUTPUTS) ---

output "kong_public_ip" {
  description = "Public IP address for the Kong circuit breaker instance"
  value       = aws_instance.kong.public_ip
}

output "provesi_servidor_public_ip" {
  description = "Public IP address for the Provesi application server"
  value       = aws_instance.provesi_servidor.public_ip
}

output "provesi_servidor_private_ip" {
  description = "Private IP address for the Provesi application server"
  value       = aws_instance.provesi_servidor.private_ip
}

output "provesi_db_a_private_ip" {
  description = "Private IP address for the PostgreSQL database instance A"
  value       = aws_instance.provesi_db_a.private_ip
}

output "provesi_db_b_private_ip" {
  description = "Private IP address for the PostgreSQL database instance B"
  value       = aws_instance.provesi_db_b.private_ip
}
