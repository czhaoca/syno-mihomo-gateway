import react from "eslint-plugin-react";
import globals from "globals";

// Flat config, deliberately small. `no-unused-vars` cannot see JSX usage on
// its own - it would report every imported component as dead - so the React
// plugin's jsx-uses-vars is what makes the rule mean anything here.
export default [
  {
    files: ["src/**/*.{js,jsx}"],
    plugins: { react },
    languageOptions: {
      ecmaVersion: "latest",
      sourceType: "module",
      globals: { ...globals.browser },
      parserOptions: { ecmaFeatures: { jsx: true } },
    },
    rules: {
      "no-unused-vars": "error",
      "no-undef": "error",
      "react/jsx-uses-vars": "error",
      "react/jsx-uses-react": "error",
    },
  },
];
