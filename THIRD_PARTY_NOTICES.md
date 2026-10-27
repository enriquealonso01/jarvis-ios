# Third-party notices

## Hermex

JARVIS is a fork of Hermex (https://github.com/uzairansaruzi/hermex) by Uzair Ansar, used under
the MIT License. See `LICENSE`.

## LiveKit Agents UI: AgentAudioVisualizerAura

The voice screen's Aura visualizer (`HermesMobile/Features/Calls/JarvisAuraVisualizer.swift`) is a
native Swift and Metal port of `AgentAudioVisualizerAura` and `useAgentAudioVisualizerAura` from
LiveKit Agents UI (https://livekit.com/products/agents-ui, source in
https://github.com/livekit/components-js), Copyright LiveKit, Inc.

The fragment shader is a translation of the original GLSL into Metal Shading Language, and the
state animation is a port of the original React hook. Both were changed to fit Swift and the
JARVIS call (the colour is Jarvis Cyan #3FD6F5 instead of #1FD5F9, and the state comes from the
call). The original is licensed under the Apache License, Version 2.0:

    Licensed under the Apache License, Version 2.0 (the "License");
    you may not use this file except in compliance with the License.
    You may obtain a copy of the License at

        http://www.apache.org/licenses/LICENSE-2.0

    Unless required by applicable law or agreed to in writing, software
    distributed under the License is distributed on an "AS IS" BASIS,
    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
    See the License for the specific language governing permissions and
    limitations under the License.
