ALTER TABLE users ADD COLUMN normalized_email TEXT;
UPDATE users SET normalized_email = lower(email);
