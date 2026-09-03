import nextConfig from "eslint-config-next";

const eslintConfig = [...nextConfig, { ignores: ["src/abis/vault.ts"] }];

export default eslintConfig;
