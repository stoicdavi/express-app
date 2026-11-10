FROM node:26

COPY . .

RUN npm install

CMD ["node", "index.js"]