/** @type {import('next').NextConfig} */
const nextConfig = {
  transpilePackages: ['lunar-javascript'],
  // better-sqlite3 是原生模块，不能交给打包器处理
  serverExternalPackages: ['better-sqlite3'],
  poweredByHeader: false,
};

module.exports = nextConfig;
