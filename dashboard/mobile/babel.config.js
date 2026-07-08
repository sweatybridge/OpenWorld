module.exports = function (api) {
  api.cache(true);
  return {
    presets: ["babel-preset-expo"],
    // Reanimated v4's babel plugin is added automatically by babel-preset-expo;
    // the manual "react-native-reanimated/plugin" entry is no longer needed.
  };
};
