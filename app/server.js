const http = require('http');
const port = 3000;

const server = http.createServer((req, res) => {
  res.statusCode = 200;
  res.setHeader('Content-Type', 'text/plain');
  res.end('Hello! Your custom Node.js application is running live in EKS and scaling up smoothly.\n');
});

server.listen(port, () => {
  console.log(`Server listening directly on port ${port}`);
});
