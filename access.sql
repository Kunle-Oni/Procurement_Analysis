CREATE USER 'powerbi'@'%' IDENTIFIED WITH mysql_native_password BY 'investorG1$';
GRANT SELECT ON inventory_procurement.* TO 'powerbi'@'%';
FLUSH PRIVILEGES;

