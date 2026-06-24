# :trophy: SonarQube on Minikube with Terraform and Custom Helm Charts - DevOps Engineer Assigned Challenge by Mintos

This project deploys SonarQube Community Edition with PostgreSQL on Minikube.

The deployment is automated with:

- Terraform
- Custom Helm charts
- Minikube
- Docker
- Kubernetes StatefulSets
- Persistent storage

> It was tested successfully on a fresh Ubuntu EC2 t2.large instance.

## :ship: What Is Deployed

The deployment creates one Kubernetes namespace:

``sonarqube``

Inside this namespace, it deploys:

PostgreSQL
- StatefulSet
- Service
- PersistentVolumeClaim
- Secret

SonarQube
- StatefulSet
- Service
- PersistentVolumeClaim
- Secret

> PostgreSQL is used as the external database for SonarQube.

## :computer: Requirements

The script installs all required tools automatically:

- Docker
- kubectl
- Helm
- Terraform
- Minikube

Recommended machine size:

2 CPU

4 GB RAM - minimum

8 GB RAM - recommended

For AWS EC2, ``t2.large`` was tested successfully.

## :rocket: Deployment

Clone the repository:

``git clone https://github.com/Dr3xel/sonar-helm-mintos.git``

``cd /sonar-helm-mintos``

Make the script executable:

``chmod +x setup.sh``

Run the deployment:

``./setup.sh``

## :grey_question: What ``setup.sh`` Does

- Installs required packages and tools
- Starts Minikube
- Enables the ingress addon
- Applies required SonarQube sysctl settings
- Runs Helm lint checks
- Deploys PostgreSQL and SonarQube using Terraform
- Waits for the StatefulSets to become ready
- Starts port-forwarding from port 80 to SonarQube port 9000

## :accessibility: Access SonarQube

Open: ``http://<PUBLIC_IP>``

Default login:

Username: admin

Password: admin

> SonarQube will ask you to change the password after the first login.

## :scroll: Important Notes

This project is intended for <ins>local or test usage only</ins>. 

For production, the following <ins>improvements</ins> would be needed:

- Use a managed Kubernetes cluster instead of Minikube
- Use a managed PostgreSQL database
- Store secrets in a real secret manager
- Enable HTTPS/TLS
- Restrict public access
- Add monitoring and backups
- Configure production resource requests and limits1
