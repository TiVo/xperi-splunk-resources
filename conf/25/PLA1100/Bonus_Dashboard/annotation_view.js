{
    "title": "Annotation View",
    "description": "",
    "inputs": {
        "input_XcMqEgCO": {
            "options": {
                "defaultValue": "",
                "token": "text_mainSPL"
            },
            "title": "Main SPL",
            "type": "input.text"
        },
        "input_global_trp": {
            "options": {
                "defaultValue": "-24h@h,now",
                "token": "global_time"
            },
            "title": "Global Time Range",
            "type": "input.timerange"
        },
        "input_qabjayRv": {
            "options": {
                "defaultValue": "",
                "token": "text_annotationSPL"
            },
            "title": "Annotation SPL",
            "type": "input.text"
        }
    },
    "defaults": {
        "dataSources": {
            "ds.search": {
                "options": {
                    "queryParameters": {
                        "earliest": "$global_time.earliest$",
                        "latest": "$global_time.latest$"
                    }
                }
            }
        }
    },
    "visualizations": {
        "viz_NDMur7nM": {
            "options": {
                "markdown": "### Notes:\nThere are a couple of pre-defined fields that you can use in your annotation SPL that will allow you to impact how the charts are generated:\n* **annotationLabel**: This allows you to set the label associated with the annotation line, e.g. `|eval annotationLabel=\"magic event\"`\n* **annotationColor**: This allows you to set the color of the annotation line, e.g. `| eval annotationColor=\"#424242\"`"
            },
            "type": "splunk.markdown"
        },
        "viz_Q2DFEVKa": {
            "options": {
                "markdown": "**Main SPL**:\n`$text_mainSPL$`\n\n**Annotation SPL**:\n`$text_annotationSPL$`"
            },
            "type": "splunk.markdown"
        },
        "viz_Sm26KRcQ": {
            "dataSources": {
                "annotation": "ds_yiaTemCj",
                "primary": "ds_aEik8zzI"
            },
            "options": {
                "annotationColor": "> annotation | seriesByName('annotationColor')",
                "annotationLabel": "> annotation | seriesByName('annotationLabel')",
                "annotationX": "> annotation | seriesByName('_time')"
            },
            "type": "splunk.line"
        }
    },
    "dataSources": {
        "ds_aEik8zzI": {
            "name": "MainSearch",
            "options": {
                "query": "$text_mainSPL$",
                "queryParameters": {
                    "earliest": "$global_time.earliest$",
                    "latest": "$global_time.latest$"
                }
            },
            "type": "ds.search"
        },
        "ds_yiaTemCj": {
            "name": "AnnotationSearch",
            "options": {
                "query": "$text_annotationSPL$",
                "queryParameters": {
                    "earliest": "$global_time.earliest$",
                    "latest": "$global_time.latest$"
                }
            },
            "type": "ds.search"
        }
    },
    "layout": {
        "globalInputs": [
            "input_global_trp"
        ],
        "layoutDefinitions": {
            "layout_1": {
                "options": {
                    "height": 960,
                    "width": 1440
                },
                "structure": [
                    {
                        "item": "input_XcMqEgCO",
                        "position": {
                            "h": 90,
                            "w": 1440,
                            "x": 0,
                            "y": 0
                        },
                        "type": "input"
                    },
                    {
                        "item": "input_qabjayRv",
                        "position": {
                            "h": 90,
                            "w": 1440,
                            "x": 0,
                            "y": 90
                        },
                        "type": "input"
                    },
                    {
                        "item": "viz_NDMur7nM",
                        "position": {
                            "h": 113,
                            "w": 1440,
                            "x": 0,
                            "y": 180
                        },
                        "type": "block"
                    },
                    {
                        "item": "viz_Sm26KRcQ",
                        "position": {
                            "h": 400,
                            "w": 1440,
                            "x": 0,
                            "y": 293
                        },
                        "type": "block"
                    },
                    {
                        "item": "viz_Q2DFEVKa",
                        "position": {
                            "h": 400,
                            "w": 1440,
                            "x": 0,
                            "y": 693
                        },
                        "type": "block"
                    }
                ],
                "type": "grid"
            }
        },
        "tabs": {
            "items": [
                {
                    "label": "New tab",
                    "layoutId": "layout_1"
                }
            ]
        }
    }
}