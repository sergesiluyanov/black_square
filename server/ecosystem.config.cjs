/**
 * PM2 конфиг — автоперезапуск при падении и автозапуск при перезагрузке сервера
 * Использование: pm2 start ecosystem.config.cjs
 */
module.exports = {
  apps: [{
    name: 'black-square',
    script: 'index.js',
    cwd: __dirname,
    instances: 1,
    autorestart: true,
    watch: false,
    max_memory_restart: '200M',
    env: {
      NODE_ENV: 'production',
      PORT: 8080,
    },
  }],
};
