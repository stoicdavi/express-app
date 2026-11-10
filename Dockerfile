FROM node:20

COPY . .

RUN npm install

CMD ["node", "index.js"]