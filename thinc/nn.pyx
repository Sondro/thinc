cimport cython

from cymem.cymem cimport Pool

from .typedefs cimport weight_t, atom_t

from libc.string cimport memcpy
from libc.math cimport isnan, sqrt


@cython.cdivision(True)
cdef void Param_asgd(Param* self, float* grad, int t, float eta, float mu) except *:
    cdef int i
    cdef float alpha = (1 / t)
    alpha = alpha if alpha >= 0.001 else 0.001
    alpha = alpha if alpha < 0.9 else 0.9

    for i in range(self.length):
        self.step[i] = (mu * self.step[i]) - grad[i]
        self.curr[i] += (eta * self.step[i])
        if t < 1000:
            self.avg[i] = self.curr[i]
        else:
            self.avg[i] = ((1 - alpha) * self.avg[i]) + (alpha * self.curr[i])


@cython.cdivision(True)
cdef void Param_sgd_cm(Param* self, float* grad, int t, float eta, float mu) except *:
    cdef int i
    for i in range(self.length):
        self.step[i] = (mu * self.step[i]) - grad[i]
        self.curr[i] += (eta * self.step[i])


@cython.cdivision(True)
cdef void Param_adadelta(Param* self, float* grad, int t, float rho, float epsilon) except *:
    cdef float accu, delta_accu, curr, g
    cdef float accu_new, delta_accu_new, upd
    cdef int i

    for i in range(self.length):
        accu = self.avg[i]
        delta_accu = self.step[i]
        curr = self.curr[i]
        g = grad[i]

        accu_new = rho * accu + (1-rho) * g ** 2
        upd = (g * sqrt(delta_accu + epsilon) / sqrt(accu_new + epsilon))
        delta_accu_new = rho * delta_accu

        self.curr[i] -= upd
        self.avg[i] = accu_new
        self.step[i] = delta_accu_new


cdef Param Param_init(Pool mem, int length, initializer) except *:
    cdef Param param
    param.curr = <float*>mem.alloc(length, sizeof(float))
    param.avg = <float*>mem.alloc(length, sizeof(float))
    param.step = <float*>mem.alloc(length, sizeof(float))
    param.update = Param_asgd
    param.length = length

    # Draw random values from the initializer. avg and curr should have the same
    # values. Step is initialized to 0s
    for i in range(length):
        param.curr[i] = initializer()
        param.avg[i] = 0
    return param


cdef class EmbeddingTable:
    def __init__(self, n_cols, initializer):
        self.mem = Pool()
        self.initializer = initializer
        self.n_cols = n_cols
        self.table = PreshMap()

    cdef Param* get(self, atom_t key) except NULL:
        param = <Param*>self.table.get(key)
        if param is NULL:
            param = <Param*>self.mem.alloc(1, sizeof(Param))
            param[0] = Param_init(self.mem, self.n_cols, self.initializer)
            self.table.set(key, param)
        return param


cdef class InputLayer:
    '''An input layer to an NN.'''
    def __init__(self, input_structure, initializer):
        self.mem = Pool()
        self.length = 0
        self.tables = []
        self.indices = []
        for i, (n_cols, fields) in enumerate(input_structure):
            self.tables.append(EmbeddingTable(n_cols, initializer))
            self.indices.append(fields)
            self.length += len(fields) * n_cols

    def __len__(self):
        return self.length
    
    @cython.boundscheck(False)
    def fill(self, float[:] output, atom_t[:] context, use_avg=False):
        cdef int i, j, idx, c
        cdef EmbeddingTable table
        cdef const Param* param
        c = 0
        for table, fields in zip(self.tables, self.indices):
            for idx in fields:
                param = table.get(context[idx])
                if use_avg:
                    memcpy(&output[c], param.avg, param.length * sizeof(float))
                else:
                    memcpy(&output[c], param.curr, param.length * sizeof(float))
                c += param.length

    @cython.boundscheck(False)
    def update(self, float[:] gradient, atom_t[:] context, t, eta, mu):
        cdef int i, j, idx, c
        cdef EmbeddingTable table
        cdef Param* param
        c = 0
        for table, fields in zip(self.tables, self.indices):
            for idx in fields:
                param = table.get(context[idx])
                param.update(param, &gradient[c], t, eta, mu)
                c += param.length


cdef struct DenseC:
    float[4][300] W
    float[4][300] b
    const int depth = 4
    const int width = 300


def softmax(actvn, W, b):
    w = W.dot(actvn) + b
    ew = numpy.exp(w - max(w))
    return (ew / sum(ew)).ravel()


def relu(actvn, W, b):
    x = W.dot(actvn) + b
    return x * (x > 0)


def d_relu(x):
    return x > 0


class Adagrad(object):
    def __init__(self, lr, rho, shape):
        self.eps = 1e-3
        # initial learning rate
        self.learning_rate = lr
        self.rho = rho
        # stores sum of squared gradients 
        self.h = numpy.zeros(gradient.data.shape)
        self._curr_rate = 
    
    def __call__(self, weights, gradient, batch_size, word_freqs):
        self.L2_penalty(gradient, weights, word_freqs)
        update = self.rescale(gradient.data / batch_size)
        weights.data -= update

    def rescale(self, gradient):
        curr_rate = numpy.zeros(gradient.data.shape)
        self.h += gradient ** 2
        curr_rate = self.learning_rate / (numpy.sqrt(self.h) + self.eps)
        return curr_rate * gradient

    def L2_penalty(self, gradient, weights, features):
        # L2 Regularization
        for i in range(len(weights.W)):
            gradient.W[i] += weights.W[i] * self.rho
            gradient.b[i] += weights.b[i] * self.rho
        for w, freq in features.items():
            if w < gradient.E.shape[0]:
                gradient.E[w] += weights.E[w] * self.rho


class Params(object):
    @classmethod
    def zero(cls, depth, n_embed, n_hidden, n_labels, n_vocab):
        return cls(depth, n_embed, n_hidden, n_labels, n_vocab, lambda x: numpy.zeros((x,)))

    @classmethod
    def random(cls, depth, nE, nH, nL, nV):
        return cls(depth, nE, nH, nL, nV, lambda x: (numpy.random.rand(x) * 2 - 1) * 0.08)

    def __init__(self, depth, n_embed, n_hidden, n_labels, n_vocab, initializer):
        nE = n_embed; nH = n_hidden; nL = n_labels; nV = n_vocab
        n_weights = sum([
            (nE * nH) + nH, 
            (nH * nH  + nH) * depth,
            (nH * nL) + nL,
            (nV * nE)
        ])
        self.data = initializer(n_weights)
        self.W = []
        self.b = []
        i = self._add_layer(0, nE, nH)
        for _ in range(1, depth):
            i = self._add_layer(i, nH, nH)
        i = self._add_layer(i, nL, nH)
        self.E = self.data[i : i + (nV * nE)].reshape((nV, nE))
        self.E.fill(0)

    def _add_layer(self, start, x, y):
        end = start + (x * y)
        self.W.append(self.data[start : end].reshape((x, y)))
        self.b.append(self.data[end : end + x].reshape((x, )))
        return end + x