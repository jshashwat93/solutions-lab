output "access_vms" {
  description = "Use SSM to access your VMs"
  value = <<-EOT
    Run the following:
       
      For Cloud VM (AWS): aws ssm start-session --target ${aws_instance.cloud.id}
      For On-prem VM (GCP): gcloud compute ssh ${google_compute_instance.on_prem.name} --zone ${google_compute_instance.on_prem.zone} --tunnel-through-iap

      AWS IP Address: ${aws_instance.cloud.private_ip}
      GCP IP Address: ${google_compute_instance.on_prem.network_interface[0].network_ip}

      You must have AWS CLI installed and configured on your local machine to run this command. 
      If you get an error saying "SessionManagerPlugin is not found", you will also need to install the plugin on your computer. 
      See: https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html

      You must run "gcloud auth login" from your CLI before SSHing into the GCP VM

   EOT
}