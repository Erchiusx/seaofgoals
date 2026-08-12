FROM node:latest

WORKDIR /app

COPY . .

ENV API_TOKEN=development-secret

RUN npm install
RUN npm run lint || true

EXPOSE 3000

CMD ["npm", "start"]
