module.exports = function (api) {
  api.cache(true);
  return {
    presets: ["babel-preset-expo"],
    // reanimated/plugin MUST be last.
    plugins: ["react-native-reanimated/plugin"],
  };
};
