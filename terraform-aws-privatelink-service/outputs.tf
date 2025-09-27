output "access_ec2" {
  description = "Use SSM to access your EC2 instance"
  value = <<-EOT
    Run the following:
       
      Provider Instance: aws ssm start-session --target ${aws_instance.provider.id}
      Consumer Instance: aws ssm start-session --target ${aws_instance.consumer.id}

      Consumer VPC Endpoint FQDN: ${aws_route53_record.consumer.fqdn}

      You must have AWS CLI installed and configured on your local machine to run this command. 
      If you get an error saying "SessionManagerPlugin is not found", you will also need to install the plugin on your computer. 
      See: https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html

   EOT
}