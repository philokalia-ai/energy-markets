import { defineConfig } from 'vitepress'

export default defineConfig({
  title: 'Euphemia Energy Markets',
  description: 'Day-ahead electricity market simulation and optimization',

  themeConfig: {
    nav: [
      { text: 'Home', link: '/' },
      { text: 'Data', link: '/data/' },
      { text: 'Analyses', link: '/analyses/' },
      { text: 'Results', link: '/results/' },
    ],

    sidebar: {
      '/analyses/': [
        {
          text: 'Methodology',
          items: [
            { text: 'Overview', link: '/analyses/' },
            { text: 'Generator Parameter Inference', link: '/analyses/parameter-inference' },
            { text: 'Gas Plant Classification', link: '/analyses/gas-classification' },
          ],
        },
      ],
      '/results/': [
        {
          text: 'Results',
          items: [
            { text: 'Overview', link: '/results/' },
            { text: 'Price Comparison', link: '/results/price-comparison' },
            { text: 'Zone Summary', link: '/results/zone-summary' },
          ],
        },
      ],
    },

    socialLinks: [
      { icon: 'github', link: 'https://github.com/silentech-inc/energy-markets' },
    ],
  },
})
