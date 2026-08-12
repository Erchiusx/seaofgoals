CREATE TABLE demo_entity (
  id BIGINT AUTO_INCREMENT PRIMARY KEY,
  username VARCHAR(255),
  deleted BIT(1) NOT NULL DEFAULT b'0',
  created_at DATETIME NOT NULL
);

CREATE TABLE demo_profile (
  user_id BIGINT PRIMARY KEY,
  display_name VARCHAR(255)
);

CREATE TABLE demo_order_detail (
  id BIGINT AUTO_INCREMENT PRIMARY KEY,
  user_id BIGINT NOT NULL,
  flag_col BIT(1),
  status_col VARCHAR(32),
  amount_col DECIMAL(10, 2)
);
