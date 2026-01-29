resource "aws_s3_bucket" "bucket1" {
  bucket = "sk-module2.2-s3"  
  force_destroy = true
}
