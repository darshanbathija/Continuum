"""pytest config + fixtures for clawdmeter-agents."""

import os
import sys

# Make the sidecar modules importable without installing.
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
