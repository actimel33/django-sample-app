################################################
#                     VPC                      #
################################################

################
# aws_vpc.main #
################
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${local.name_prefix}-vpc" }
}

#############################
# aws_internet_gateway.main #
#############################
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = { Name = "${local.name_prefix}-igw" }
}

################################################
#               Публичные подсети              #
################################################
# Здесь живут только ALB и NAT-шлюз. Инстансов в публичных подсетях нет —
# это требование задания.

#####################
# aws_subnet.public #
#####################
resource "aws_subnet" "public" {
  # for_each по индексам, а не count: удаление подсети из списка не сдвинет
  # адреса остальных и не заставит Terraform их пересоздавать.
  for_each = { for idx, cidr in var.public_subnet_cidrs : tostring(idx) => cidr }

  vpc_id                  = aws_vpc.main.id
  cidr_block              = each.value
  availability_zone       = local.azs[tonumber(each.key)]
  map_public_ip_on_launch = true

  tags = {
    Name = "${local.name_prefix}-public-${local.azs[tonumber(each.key)]}"
    Tier = "public"
  }
}

################################################
#               Приватные подсети              #
################################################

######################
# aws_subnet.private #
######################
resource "aws_subnet" "private" {
  for_each = { for idx, cidr in var.private_subnet_cidrs : tostring(idx) => cidr }

  vpc_id            = aws_vpc.main.id
  cidr_block        = each.value
  availability_zone = local.azs[tonumber(each.key)]

  tags = {
    Name = "${local.name_prefix}-private-${local.azs[tonumber(each.key)]}"
    Tier = "private"
  }
}

################################################
#                   NAT-шлюз                   #
################################################
# ЗАЧЕМ, хотя на неделе 3 мы его избегали: инстансы в приватных подсетях, а им
# нужен интернет — dnf, pip, git clone с GitHub. Ещё InstallDependencies
# документа AWS-ApplyAnsiblePlaybooks ставит Ansible из PyPI, а агенту SSM
# нужен выход к своим эндпоинтам — без NAT инстанс даже не появится в SSM.
#
# ЦЕНА: около $0.05/час плюс трафик — самая дорогая позиция недели.
#
# ОДИН ШЛЮЗ, А НЕ ПО ОДНОМУ НА ЗОНУ: так отказоустойчивее, но стоимость удваивается.
# Падение зоны с NAT лишит интернета обе приватные подсети

###############
# aws_eip.nat #
###############
resource "aws_eip" "nat" {
  domain = "vpc"

  tags = { Name = "${local.name_prefix}-nat-eip" }
}

########################
# aws_nat_gateway.main #
########################
resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = local.public_subnet_ids[0]

  # NAT без интернет-шлюза в VPC не заработает.
  depends_on = [aws_internet_gateway.main]

  tags = { Name = "${local.name_prefix}-nat" }
}

################################################
#             Таблицы маршрутизации            #
################################################

##########################
# aws_route_table.public #
##########################
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = { Name = "${local.name_prefix}-public-rt" }
}

######################################
# aws_route_table_association.public #
######################################
resource "aws_route_table_association" "public" {
  for_each = aws_subnet.public

  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

###########################
# aws_route_table.private #
###########################
# Приватная таблица выпускает наружу через NAT.
# Забыть этот маршрут — классика: инстанс поднялся, но в SSM не появился,
# а dnf install висит до таймаута.
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }

  tags = { Name = "${local.name_prefix}-private-rt" }
}

#######################################
# aws_route_table_association.private #
#######################################
resource "aws_route_table_association" "private" {
  for_each = aws_subnet.private

  subnet_id      = each.value.id
  route_table_id = aws_route_table.private.id
}
