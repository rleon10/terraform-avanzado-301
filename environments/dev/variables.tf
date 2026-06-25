locals {
  name_prefix = "${var.project}-${var.environment}"
  common_tags = {
    Project     = var.project
    Environment = var.environment
    Owner       = "plataforma-dev"
  }
}


variable "project" {
  type        = string
  description = "Nombre corto del proyecto"
}

variable "environment" {
  type        = string
  description = "Entorno: dev, test o prod"
}

variable "aws_region" {
  type        = string
  description = "Región de AWS de referencia"
  default     = "eu-west-1"
}