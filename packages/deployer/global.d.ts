import type { Network } from 'lucid-cardano';

declare global {
  namespace NodeJS {
    interface ProcessEnv {
      NODE_ENV: 'development' | 'production';
      // Passphrase for automatic deployment
      SEED: string;
      NETWORK: Network;
      KOIOS_PROJECT_ID?: string;
    }
  }
}

// If this file has no import/export statements (i.e. is a script)
// convert it into a module by adding an empty export statement.
export {};
