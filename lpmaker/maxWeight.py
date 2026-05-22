import networkx as nx
import sys


def sortdict(d):
    s = list(d.items())
    s.sort()
    print('{' + ', '.join(map(lambda t: ': '.join(map(repr, t)), s)) + '}')


G = nx.read_weighted_edgelist(sys.argv[1], nodetype=int)

orig_stdout = sys.stdout
f = open(sys.argv[2], 'w')
sys.stdout = f

matching = nx.max_weight_matching(G, maxcardinality=True)
if isinstance(matching, dict):
    mate = matching
else:
    mate = {}
    for u, v in matching:
        mate[u] = v
        mate[v] = u

for x in range(0, len(G)):
    if mate.get(x) is not None:
        print(x, mate.get(x))

sys.stdout = orig_stdout
f.close()
