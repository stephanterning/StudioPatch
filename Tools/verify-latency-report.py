"""Compare independent cable/timestamp observations with contemporaneous HAL reports.

Usage: python3 Tools/verify-latency-report.py PREFIX DIRECT_FRAMES HW_INPUT HW_OUTPUT
PREFIX is a StudioPatch capture with direct Sync Source input as observer.
The direct hardware round trip is used only to remove the physical cable/converters
from the output-side software-delay measurement, never split into one-way values.
"""
import importlib.util
import json
import sys
from pathlib import Path
import numpy as np

spec = importlib.util.spec_from_file_location('latency_analysis', Path(__file__).with_name('analyze-latency.py'))
analysis = importlib.util.module_from_spec(spec)
spec.loader.exec_module(analysis)
prefix, direct, hardware_input, hardware_output = sys.argv[1:]
direct, hardware_input, hardware_output = map(float, (direct, hardware_input, hardware_output))
loop = analysis.analyze(prefix+'-output', prefix+'-input')
observer = analysis.analyze(prefix+'-output', prefix+'-observer-input')
reports = np.genfromtxt(prefix+'-reports.csv', delimiter=',', names=True)
rows = []
for complete, physical in zip(loop['measurements'], observer['measurements']):
    observed_input_added = complete['frames'] - physical['frames']
    observed_output_added = physical['frames'] - direct
    # The output marker follows the output samples. The input marker follows
    # the corresponding input samples a fraction of a second later. At the
    # measured slow drift the difference is below one sample; keep raw traces.
    report = reports[np.argmin(abs(reports['host'] - complete['output_host']))]
    expected_input = observed_input_added + hardware_input
    expected_output = observed_output_added + hardware_output
    rows.append(dict(reference_seconds=complete['reference_seconds'],
                     input_expected=expected_input, input_reported=float(report['input']),
                     input_error=float(report['input'])-expected_input,
                     output_expected=expected_output, output_reported=float(report['output']),
                     output_error=float(report['output'])-expected_output,
                     total_reported=float(report['input']+report['output']),
                     loop_measured=complete['frames'],
                     correlation_valid=complete['valid'] and physical['valid']))
print(json.dumps(dict(prefix=prefix,direct_reference_frames=direct,
                      hardware_residual=direct-hardware_input-hardware_output,
                      measurements=rows),indent=2))
