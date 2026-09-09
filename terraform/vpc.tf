resource "aws_vpc" "main"{
    cidr_block = "10.0.0.0/16"
    enable_dns_support = true   
    enable_dns_hostnames = true
    tags = {Name = "${var.pro_name}-vpc"}   
}

resource "aws_subnet" "public" {
    count = 2
    vpc_id = aws_vpc.main.id
    availability_zone = "${var.az[count.index]}"
    cidr_block = "10.0.${count.index}.0/24"
    map_public_ip_on_launch = true
    tags = {
    Name = "${var.pro_name}-public-${count.index}"
    "kubernetes.io/role/elb" = "1"
    "kubernetes.io/cluster/${var.cluster}" = "shared"
}
}

resource "aws_subnet" "private" {
    count = 2
    vpc_id = aws_vpc.main.id
    availability_zone = "${var.az[count.index]}"
    cidr_block = "10.0.${count.index + 10}.0/24"
    tags = {
    Name = "${var.pro_name}-private-${count.index}"
    "kubernetes.io/role/internal-elb" = "1"
    "kubernetes.io/cluster/${var.cluster}" = "shared"
}
}

resource "aws_internet_gateway" "gw" {
    vpc_id = aws_vpc.main.id

}

resource "aws_route_table" "public_table" {
    vpc_id = aws_vpc.main.id
    tags = {Name = "${var.pro_name}-vpc-public_table"}
}

resource "aws_route" "rule1"{
    route_table_id = aws_route_table.public_table.id
    destination_cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.gw.id
}

resource "aws_route_table_association" "link_rule" {
    route_table_id = aws_route_table.public_table.id
    count = 2
    subnet_id = aws_subnet.public[count.index].id
}

resource "aws_eip" "nat" {
    domain = "vpc"
}

resource "aws_nat_gateway" "ngw" {
    allocation_id = aws_eip.nat.id
    subnet_id = aws_subnet.public[0].id 
    depends_on = [aws_internet_gateway.gw]
}

resource "aws_route_table" "private"{
    vpc_id = aws_vpc.main.id
    tags = {Name = "${var.pro_name}-vpc-private_table"}
}

 resource "aws_route" "rule2" {
    route_table_id = aws_route_table.private.id
    destination_cidr_block = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.ngw.id
 }  

 resource "aws_route_table_association" "rulelink" {
    count = 2
    subnet_id = aws_subnet.private[count.index].id
    route_table_id = aws_route_table.private.id
 }

