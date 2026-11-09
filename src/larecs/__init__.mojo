"""
Larecs🌲 is a performance-oriented archetype-based ECS for Mojo.

It is based on the ECS [Arche](https://github.com/mlange-42/arche), implemented in the Go programming language.

Larecs 1.0 is currently in beta, so public APIs may still change before the
stable 1.0.0 release. After that release, public APIs follow semantic
versioning unless they are explicitly marked experimental. Device execution is
currently such an experimental API. Threaded host execution is also experimental.

Build the [particle simulation](../start/first_simulation/)
for a complete program using systems and kernels. You can find its source in
`examples/particles/movement.mojo`.

Exports:
 - world.World
 - host_storage.HostStorage
 - error.LarecsError
 - error.WorldError
 - error.ComponentError
 - error.EntityError
 - error.UnknownError
 - component.ComponentType
 - component.Components
 - types.ComponentId
 - archetype.MutArchetypeRowAccessor
 - archetype.ArchetypeRowAccessor
 - resource.Resources
 - resource.ResourceStorage
 - resource.ResourceType
 - entity.Entity
 - lock.LockGuard
 - lock.LockManager
 - filter.Filter
 - filter.BitMaskFilter
 - system.System
 - system.SystemContext
 - system.KernelContext
 - system.EntitySelection
 - entity.EntityRange
 - scheduler.Scheduler
 - capture.Captures
 - capture.ReadCapture
 - capture.MutCapture
 - capture.read_capture
 - capture.mut_capture
 - spatial.SpatialClassifier
 - spatial.grid_cell
 - spatial.morton_key_3d
 - sync.AtomicValue
 - sync.AtomicView
 - sync.CompareExchangeResult
 - sync.Synchronized
 - sync.SyncView
 - sync.TryAccess
 - resource_adapter.DevicePassableResource
 - resource_adapter.ResourceAccess
 - resource_adapter.ResourceAdapter
 - resource_adapter.ResourceDeviceCache
 - resource_adapter.ReadBuffer
 - resource_adapter.BufferResource
 - execution.ExecutionBackend
 - execution.ThreadedExecutionConfig
 - resource_representation.PlainValue
"""
from .world import World
from .host_storage import HostStorage
from .error import (
    LarecsError,
    WorldError,
    ComponentError,
    EntityError,
    UnknownError,
)
from .component import ComponentType, Components
from .types import ComponentId
from .archetype import MutArchetypeRowAccessor, ArchetypeRowAccessor
from .resource import Resources, ResourceStorage, ResourceType
from .entity import Entity
from .lock import LockGuard, LockManager
from .filter import Filter, BitMaskFilter
from .system import System, SystemContext, KernelContext, EntitySelection
from .entity import EntityRange
from .scheduler import Scheduler

from .capture import (
    Captures,
    ReadCapture,
    MutCapture,
    read_capture,
    mut_capture,
)

from .spatial import SpatialClassifier, grid_cell, morton_key_3d

from .sync import (
    AtomicValue,
    AtomicView,
    CompareExchangeResult,
    Synchronized,
    SyncView,
    TryAccess,
)

from .resource_adapter import (
    DevicePassableResource,
    ResourceAccess,
    ResourceAdapter,
    ResourceDeviceCache,
    ReadBuffer,
    BufferResource,
)

from .execution import ExecutionBackend, ThreadedExecutionConfig
from .resource_representation import PlainValue
