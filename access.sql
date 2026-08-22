CREATE USER 'powerbi'@'%' IDENTIFIED WITH mysql_native_password BY 'investorG1$';
GRANT SELECT ON inventory_procurement.* TO 'powerbi'@'%';
FLUSH PRIVILEGES;



CREATE USER 'loader'@'%' IDENTIFIED BY 'investorG1$';
GRANT SELECT, INSERT, UPDATE, DELETE, TRUNCATE ON inventory_procurement.* TO 'loader'@'%';
FLUSH PRIVILEGES;


SELECT MIN(posting_date), MAX(posting_date), COUNT(*) FROM mobo15_movements;