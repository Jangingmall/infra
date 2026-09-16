\getenv app_password AI_DB_PASSWORD
CREATE ROLE ai_chatbot LOGIN PASSWORD :'app_password';
CREATE EXTENSION IF NOT EXISTS vector;
GRANT CONNECT ON DATABASE midam TO ai_chatbot;
GRANT USAGE, CREATE ON SCHEMA public TO ai_chatbot;
