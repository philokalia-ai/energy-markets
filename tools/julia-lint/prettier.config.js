import julia from "prettier-plugin-julia";

export default {
    plugins: [julia],
    tabWidth: 4,
    printWidth: 92,
    juliaVerify: true,
    juliaReport: true,
};
